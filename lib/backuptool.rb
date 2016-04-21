require 'fileutils'
require 'table_print'

# Buffer size, used for downloads
BUFFER_SIZE = 10_000_000

# Directory where metadata is
META_DIR = 'cass_snap_metadata'.freeze

class BackupTool
  # Create a new BackupTool instance
  # * *Args*    :
  #   - +cassandra+ -> Cassandra instance
  #   - +hadoop+ -> HDFS instance
  #   - +logger+ -> Logger
  def initialize(cassandra, hadoop, logger)
    @cassandra = cassandra
    @hadoop = hadoop
    @logger = logger

    @metadir = META_DIR
  end

  # Look for snapshots
  # * *Args*    :
  #   - +node+ -> Cassandra node name
  #   - +date+ -> HDFS instance
  def search_snapshots(node: 'ALL', date: 'ALL')
    result = []

    def get_snapshot_metadata(node, date)
      remote = @hadoop.base_dir + '/' + @metadir + '/' + @cassandra.cluster_name + '/' + node + '/cass_snap_' + date
      return @hadoop.read(remote).split("\n").to_set
    rescue Exception => e
      raise("Could not read metadata : #{e.message}")
    end

    def get_snapshots_node(node, date)
      result = []
      begin
        if date == 'ALL'
          ls = @hadoop.list("#{@hadoop.base_dir}/#{@metadir}/#{@cassandra.cluster_name}/#{node}")
          ls.each do |item|
            date = item['pathSuffix'].gsub('cass_snap_', '')
            metadata = get_snapshot_metadata(node, date)
            snapshot = CassandraSnapshot.new(@cassandra.cluster_name, node, date, metadata)
            result.push(snapshot)
          end
        else
          metadata = get_snapshot_metadata(node, date)
          snapshot = CassandraSnapshot.new(@cassandra.cluster_name, node, date, metadata)
          result.push(snapshot)
        end
      rescue Exception => e
        @logger.warn("Could not get snapshots for node #{node} : #{e.message}")
      end
      result
    end

    if node == 'ALL'
      begin
        ls = @hadoop.list("#{@hadoop.base_dir}/#{@metadir}/#{@cassandra.cluster_name}")
        ls.each do |item|
          n = item['pathSuffix']
          result += get_snapshots_node(n, date)
        end
      rescue Exception => e
        @logger.warn("Could not get snapshots for cluster #{@cassandra.cluster_name} : #{e.message}")
      end
    else
      result = get_snapshots_node(node, date)
    end

    result.sort
  end

  def list_snapshots(node: @cassandra.node_name)
    @logger.info('Listing available snapshots')
    snapshots = search_snapshots(node: node)
    tp(snapshots, 'cluster', 'node', 'date')
  end

  def new_snapshot
    @logger.info('Starting a new snapshot')
    snapshot = @cassandra.new_snapshot

    existing = search_snapshots(node: snapshot.node)
    last = if existing.empty?
             CassandraSnapshot.new(snapshot.cluster, snapshot.node, 'never')
           else
             existing[-1]
    end

    @logger.info('Uploading tables to Hadoop')
    files = snapshot.metadata - last.metadata
    @logger.info("#{files.length} files to upload")
    files.each do |file|
      @logger.info("Sending file #{file} to Hadoop")
      local = @cassandra.data_path + '/' + file
      remote = @hadoop.base_dir + '/' + snapshot.cluster + '/' + snapshot.node + '/' + file
      @logger.debug("#{local} => #{remote}")
      f = File.open(local, 'r')
      @hadoop.create(remote, f, overwrite: true)
      f.close
    end

    @logger.info('Sending metadata to Hadoop')
    remote = @hadoop.base_dir + '/' + @metadir + '/' + snapshot.cluster + '/' + snapshot.node + '/cass_snap_' + snapshot.date
    @logger.debug("metadata => #{remote}")
    @hadoop.create(remote, snapshot.metadata.to_a * "\n", overwrite: true)

    @cassandra.delete_snapshot(snapshot)
    @logger.info('Success !')
  end

  def delete_snapshots(node: @cassandra.node_name, date: 'ALL')
    snapshots = search_snapshots(node: node, date: date)
    if snapshots.empty?
      raise('No snapshot found for deletion')
    else
      snapshots.each do |snapshot|
        @logger.info("Deleting snapshot #{snapshot}")
        node_snapshots = search_snapshots(node: snapshot.node)
        merged_metadata = Set.new
        node_snapshots.each do |s|
          merged_metadata += s.metadata if s != snapshot
        end
        files = snapshot.metadata - merged_metadata
        @logger.info("#{files.length} files to delete")
        files.each do |file|
          @logger.info("Deleting file #{file}")
          remote = @hadoop.base_dir + '/' + snapshot.cluster + '/' + snapshot.node + '/' + file
          @logger.debug("DELETE => #{remote}")
          @hadoop.delete(remote)
        end
        @logger.info('Deleting metadata in Hadoop')
        remote = @hadoop.base_dir + '/' + @metadir + '/' + snapshot.cluster + '/' + snapshot.node + '/cass_snap_' + snapshot.date
        @logger.debug("DELETE => #{remote}")
        @hadoop.delete(remote)
      end
    end
  end

  # Method that creates a backup flag to signal that the backup is finished on all nodes
  # This is an individual command that has to be called manually after snapshots have finished
  def create_backup_flag(date)
    file_name = 'BACKUP_COMPLETED_' + date
    remote_file = @hadoop.base_dir + '/' + @metadir + '/' + @cassandra.cluster_name + '/' + file_name

    @logger.info('Setting backup completed flag : ' + remote_file)
    @hadoop.create(remote_file, '', overwrite: true)
  end

  # Download a file from HDFS, buffered way
  # * *Args*    :
  #   - +remote+ -> HDFS path
  #   - +local+ -> local path
  def buffered_download(remote, local)
    @logger.debug("#{remote} => #{local}")

    # Create the destination directory if not exists
    path = File.dirname(local)
    FileUtils.mkdir_p(path) unless File.exist?(path)

    file = open(local, 'wb')

    offset = 0
    length = BUFFER_SIZE
    print '['
    while length == BUFFER_SIZE
      print '#'
      content = @hadoop.read(remote, offset: offset, length: BUFFER_SIZE)
      file.write(content)
      length = content.length
      offset += length
    end
    print "]\n"

    file.close
  end

  # Restore a snapshot from HDFS
  # * *Args*    :
  #   - +node+ -> node where the snapshot comes from
  #   - +date+ -> snapshot date
  #   - +destination+ -> local directory where to restore
  def restore_snapshot(node, date, destination)
    # Search the snapshot matching node and date
    snapshots = search_snapshots(node: node, date: date)

    if snapshots.empty?
      raise('No snapshot found for restore')
    elsif snapshots.length > 1
      raise('More than one candidate snapshot to restore')
    else
      snapshot = snapshots[0]
      @logger.info("Restoring snapshot #{snapshot}")
      @logger.info("#{snapshot.metadata.length} files to restore")

      # For each file in metadata
      snapshot.metadata.each do |file|
        @logger.info("Restoring file #{file}")
        local = destination + '/' + file
        remote = @hadoop.base_dir + '/' + snapshot.cluster + '/' + snapshot.node + '/' + file
        # Download the file from hdfs
        buffered_download(remote, local)
      end
      @logger.info('Success !')
    end
  end
end
