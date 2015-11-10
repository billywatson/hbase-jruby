#!/usr/bin/env ruby

$LOAD_PATH.unshift File.expand_path('..', __FILE__)
require 'helper'

class TestTableAdmin < TestHBaseJRubyBase
  def test_create_table_symbol_string
    t = @hbase.table("hbase_jruby_#{__method__}")
    t.drop! if t.exists?

    assert_raises(ArgumentError) do
      t.create! :cf, :splits => :xxx
    end

    assert_raises(ArgumentError) do
      t.create! :cf => { 1 => 2 }
    end

    assert_raises(ArgumentError) do
      t.create! :cf, { 1 => 2 }
    end

    [ :cf, 'cf', {:cf => {}} ].map.with_index { |cf, idx|
      Thread.new do
        name = "hbase_jruby_#{__method__}_#{idx}"
        table = @hbase[name]
        assert_equal false, table.exists?
        table.create! cf
        assert table.exists?
        table.drop!
      end
    }.each(&:join)
  end

  def test_disable_and_drop
    @table.disable!
    @table.disable!
    @table.drop!
    assert_equal false, @table.exists?
  end

  def test_create_table_props
    max_fs = 1024 ** 3
    @table.drop!
    @table.create!({ :cf1 => {}, :cf2 => {} }, :max_filesize => max_fs)
    assert_equal max_fs, @table.descriptor.get_max_file_size

    max_fs = 300 * 1024 ** 2
    @table.drop!
    @table.create! :cf1, :max_filesize => max_fs
    assert_equal max_fs, @table.descriptor.get_max_file_size

    @table.drop!
  end

  def test_create_table_invalid_input
    table = @hbase[:hbase_jruby_xxx]
    assert_raises(ArgumentError) do
      table.create! 3.14
    end

    assert_raises(ArgumentError) do
      table.create! :cf1 => { :bloom => 'by beach house' }
    end

    assert_raises(ArgumentError) do
      table.create! :cf1 => { :bloomfilter => :xxx }
    end
  end

  def test_enabled_disabled
    assert @table.enabled?
    assert !@table.disabled?
    @table.disable!
    assert !@table.enabled?
    assert @table.disabled?
    @table.enable!
    assert @table.enabled?
    assert !@table.disabled?
  end

# def test_rename!
#   new_name = TABLE + '_new'
#   @table.rename! new_name
#   assert_equal new_name, @table.name
#   assert_equal new_name, @table.descriptor.get_name_as_string
#   @table.drop!
# end

  def test_table_properties
    assert_raises(ArgumentError) do
      @table.alter! :hello => :world
    end
    assert_raises(ArgumentError) do
      # Splits not allowed
      @table.alter! :readonly => :true, :splits => [1, 2, 3]
    end

    max_fs = 512 * 1024 ** 2
    mem_fs =  64 * 1024 ** 2

    progress = total = nil
    @table.alter!(
      :max_filesize       => max_fs,
      :memstore_flushsize => mem_fs,
      :readonly           => false
    ) do |p, t|
      progress = p
      total = t
    end
    assert_equal total, progress
    assert progress > 0

    assert_equal max_fs, @table.descriptor.get_max_file_size
    assert_equal mem_fs, @table.descriptor.get_mem_store_flush_size
    assert_equal false,  @table.descriptor.is_read_only

    @table.drop!
  end

  def test_column_family_alteration!
    assert @table.descriptor.getFamilies.map(&:getNameAsString).include?('cf2')
    @table.delete_family! :cf2
    assert !@table.descriptor.getFamilies.map(&:getNameAsString).include?('cf2')
    @table.add_family! :cf4, {}
    assert @table.descriptor.getFamilies.map(&:getNameAsString).include?('cf4')

    @table.alter_family! :cf4, :versions => 10
    assert_equal 10, @table.descriptor.getFamily('cf4'.to_java_bytes).getMaxVersions

    @table.alter_family! :cf4, :bloomfilter => :rowcol,
                               :config => { 'foo' => 'bar' }
    assert_equal 'ROWCOL', @table.descriptor.getFamily('cf4'.to_java_bytes).getBloomFilterType.to_s
    assert_equal 10, @table.descriptor.getFamily('cf4'.to_java_bytes).getMaxVersions

    # Method not available on 0.94
    assert_equal 'bar', @table.descriptor.getFamily('cf4'.to_java_bytes).getConfigurationValue('foo')

    assert_raises(ArgumentError) {
      @table.alter_family! :cf4, :hello => 'world'
    }
    assert_raises(ArgumentError) {
      @table.alter_family! :cf4, :bloomfilter => :xxx
    }

    @table.drop!
  end

  def test_add_coprocessor!
    coproc = 'org.apache.hadoop.hbase.coprocessor.AggregateImplementation'

    if @table.has_coprocessor? coproc
      @table.remove_coprocessor! coproc
    end

    omit "AggregationClient not found" unless @aggregation

    assert_equal false, @table.has_coprocessor?(coproc)
    assert_raises(ArgumentError) {
      # :path is missing
      @table.add_coprocessor! coproc, :priority => 100
    }
    @table.add_coprocessor! coproc
    assert @table.has_coprocessor? coproc

    @table.remove_coprocessor! coproc
    assert !@table.has_coprocessor?(coproc)

    @table.drop!
  end

  def test_inspection
    assert @table.inspect.is_a?(String)
    @table.drop!
    assert @table.inspect.is_a?(String)

    table_props = {
      :max_filesize       => 512 * 1024 ** 2,
      :memstore_flushsize => 64 * 1024 ** 2,
      :readonly           => false,
      :splits             => [10, 20, 30, 40],
      :split_policy       =>
          'org.apache.hadoop.hbase.regionserver.IncreasingToUpperBoundRegionSplitPolicy',
      'hello'             => 'world'
    }
    if org.apache.hadoop.hbase.HTableDescriptor.method_defined? :setDurability
      table_props[:durability] = :async_wal
    else
      table_props[:deferred_log_flush] = true
    end

    [
      'GZ',
      :gz,
      begin
        org.apache.hadoop.hbase.io.hfile.Compression::Algorithm::GZ
      rescue Exception
        org.apache.hadoop.hbase.io.compress.Compression::Algorithm::GZ
      end
    ].map.with_index { |cmp, idx|
      Thread.new do
        table = @hbase["hbase_jruby_#{__method__}_#{idx}"]
        table.create!({
            :cf => {
              :blockcache          => true,
              :blocksize           => 128 * 1024,
              :bloomfilter         => :row, # as Symbol
              :compression         => cmp,  # as String, Symbol, java.lang.Enum
              :compression_compact => cmp,  # as String, Symbol, java.lang.Enum
            # TODO
            # :data_block_encoding => :diff,
            # :encode_on_disk      => true,
            # :keep_deleted_cells  => true,
              :in_memory           => true,
              :min_versions        => 5,
              :replication_scope   => 0,
              :ttl                 => 100,
              :versions            => 10,
              'whatever'           => 'works',
            }
          }, table_props)

        # Initial region count
        regions = table.regions
        assert_equal 5, regions.count

        # Table properties
        props = table.properties
        assert props[:deferred_log_flush] || props[:durability] == 'ASYNC_WAL'
        assert_equal false,           props[:readonly]
        assert_equal 64 * 1024 ** 2,  props[:memstore_flushsize]
        assert_equal 512 * 1024 ** 2, props[:max_filesize]
        assert_equal 'world',         props['hello']
        assert_equal 'org.apache.hadoop.hbase.regionserver.IncreasingToUpperBoundRegionSplitPolicy',
                                      props[:split_policy]

        rprops = table.raw_properties
        assert rprops['DEFERRED_LOG_FLUSH'] == 'true' || rprops['DURABILITY'] == 'ASYNC_WAL'

        assert_equal false.to_s,             rprops['READONLY']
        assert_equal((64 * 1024 ** 2).to_s,  rprops['MEMSTORE_FLUSHSIZE'])
        assert_equal((512 * 1024 ** 2).to_s, rprops['MAX_FILESIZE'])
        assert_equal 'world',                rprops['hello']
        assert_equal 'org.apache.hadoop.hbase.regionserver.IncreasingToUpperBoundRegionSplitPolicy',
                                             rprops['SPLIT_POLICY']

        # Column family properties
        cf = table.families['cf']
        assert_equal 'ROW',  cf[:bloomfilter]
        assert_equal 0,      cf[:replication_scope]
        assert_equal 10,     cf[:versions]
        assert_equal 'GZ',   cf[:compression]
        assert_equal 5,      cf[:min_versions]
        assert_equal 100,    cf[:ttl]
        assert_equal 131072, cf[:blocksize]
        assert_equal true,   cf[:in_memory]
        assert_equal true,   cf[:blockcache]
        assert_equal 'works', cf['whatever']

        rcf = table.raw_families['cf']
        assert_equal 'ROW',       rcf['BLOOMFILTER']
        assert_equal 0.to_s,      rcf['REPLICATION_SCOPE']
        assert_equal 10.to_s,     rcf['VERSIONS']
        assert_equal 'GZ',        rcf['COMPRESSION']
        assert_equal 5.to_s,      rcf['MIN_VERSIONS']
        assert_equal 100.to_s,    rcf['TTL']
        assert_equal 131072.to_s, rcf['BLOCKSIZE']
        assert_equal true.to_s,   rcf['IN_MEMORY']
        assert_equal true.to_s,   rcf['BLOCKCACHE']
        assert_equal 'works',     rcf['whatever']

        table.put 31, 'cf:a' => 100
        table.put 37, 'cf:a' => 100
        table.split!(35)
        wait_for_regions table, 6

        table.put 39, 'cf:a' => 100
        table.split!(38)
        wait_for_regions table, 7

        regions = table.regions
        assert_equal [10, 20, 30, 35, 38, 40], regions.map { |r| HBase::Util.from_bytes :fixnum, r[:start_key] }.compact.sort
        assert_equal [10, 20, 30, 35, 38, 40], regions.map { |r| HBase::Util.from_bytes :fixnum, r[:end_key] }.compact.sort

        table.drop!
      end
    }.each(&:join)
  end

  def test_snapshots
    @hbase.admin do |admin|
      @hbase.snapshots.map { |e| e[:name] }.each do |name|
        admin.deleteSnapshot name
      end
    end

    assert_equal 0, @hbase.snapshots.length
    assert_equal 0, @table.snapshots.length

    @table.snapshot! 'hbase_jruby_test_snapshot1'
    @table.snapshot! 'hbase_jruby_test_snapshot2'

    assert_equal 2, @hbase.snapshots.length
    assert_equal 2, @table.snapshots.length # FIXME: table-wise snapshots

    @hbase.snapshots.each do |snapshot|
      assert_equal @table.name, snapshot[:table]
      assert_match(/hbase_jruby_test_snapshot[12]/, snapshot[:name])
    end

    @hbase.admin do |admin|
      admin.deleteSnapshot 'hbase_jruby_test_snapshot1'
      admin.deleteSnapshot 'hbase_jruby_test_snapshot2'
    end

    assert_equal 0, @hbase.snapshots.length
    assert_equal 0, @table.snapshots.length
  rescue Exception
    # TODO: Only works on HBase 0.94 or above
  end

private
  def wait_for_regions table, rnum, max_tries = 30
    sleep 5
    max_tries.times do |i|
      if table.regions.count == rnum && table.regions.all? { |r| r[:online] }
        return
      end
      sleep 1
    end
    assert false, "Region not split"
  end
end unless ENV['HBASE_JRUBY_TEST_SKIP_ADMIN']

