require 'securerandom'
require 'tempfile'

RSpec.describe 'Docker services', :docker do
  around do |example|
    Sync { example.run }
  end

  describe 'DynamoDB Local', :docker do
    before do
      skip 'DynamoDB Local not running (docker compose up)' unless SpecHelper.dynamodb_available?
    end

    let(:client) do
      Aws::DynamoDB::Client.new(
        endpoint: SpecHelper::DYNAMODB_ENDPOINT,
        region: 'eu-central-1',
        credentials: Aws::Credentials.new('dummy', 'dummy'),
        async_http_fallback: :raise,
      )
    end

    def create_table(client, table_name)
      client.create_table(
        table_name:,
        attribute_definitions: [
          { attribute_name: 'pk', attribute_type: 'S' },
        ],
        key_schema: [
          { attribute_name: 'pk', key_type: 'HASH' },
        ],
        provisioned_throughput: {
          read_capacity_units: 1,
          write_capacity_units: 1,
        },
      )
      client.wait_until(:table_exists, table_name:)
    end

    def delete_table(client, table_name)
      client.delete_table(table_name:)
      client.wait_until(:table_not_exists, table_name:)
    rescue Aws::DynamoDB::Errors::ResourceNotFoundException
      nil
    end

    it 'creates table, puts item, gets item, deletes table' do
      table_name = "spec-#{SecureRandom.hex(6)}"

      create_table(client, table_name)
      client.put_item(table_name:, item: { 'pk' => '1', 'name' => 'Alpha' })
      result = client.get_item(table_name:, key: { 'pk' => '1' })

      expect(result.item).to eq({ 'pk' => '1', 'name' => 'Alpha' })
    ensure
      delete_table(client, table_name)
    end

    it 'reuses connections for sequential operations' do
      cache = Async::Aws::ClientCache.new
      table_name = "spec-#{SecureRandom.hex(6)}"
      cached_client = Aws::DynamoDB::Client.new(
        endpoint: SpecHelper::DYNAMODB_ENDPOINT,
        region: 'eu-central-1',
        credentials: Aws::Credentials.new('dummy', 'dummy'),
        async_http_client_cache: cache,
        async_http_fallback: :raise,
      )

      create_table(cached_client, table_name)
      cached_client.put_item(table_name:, item: { 'pk' => '1', 'name' => 'Alpha' })
      cached_client.get_item(table_name:, key: { 'pk' => '1' })

      clients = cache.instance_variable_get(:@clients)
      expect(clients.size).to eq(1)
    ensure
      delete_table(cached_client, table_name)
      cache.close!
    end

    it 'handles 10 parallel GetItem calls' do
      table_name = "spec-#{SecureRandom.hex(6)}"

      create_table(client, table_name)
      client.put_item(table_name:, item: { 'pk' => '1', 'name' => 'Alpha' })

      results = Async do |task|
        tasks = 10.times.map do
          task.async do
            client.get_item(table_name:, key: { 'pk' => '1' }).item
          end
        end
        tasks.map(&:wait)
      end.wait

      expect(results).to all(eq({ 'pk' => '1', 'name' => 'Alpha' }))
    ensure
      delete_table(client, table_name)
    end

    it 'returns ResourceNotFoundException for missing table' do
      expect do
        client.get_item(table_name: 'missing-table', key: { 'pk' => '1' })
      end.to raise_error(Aws::DynamoDB::Errors::ResourceNotFoundException)
    end
  end

  describe 'MinIO S3', :docker do
    before do
      skip 'MinIO not running (docker compose up)' unless SpecHelper.minio_available?
    end

    let(:client) do
      Aws::S3::Client.new(
        endpoint: SpecHelper::MINIO_ENDPOINT,
        region: 'eu-central-1',
        credentials: Aws::Credentials.new('minioadmin', 'minioadmin'),
        force_path_style: true,
        async_http_fallback: :raise,
      )
    end

    def create_bucket(client, bucket)
      client.create_bucket(bucket:)
    rescue Aws::S3::Errors::BucketAlreadyOwnedByYou
      nil
    end

    def delete_bucket(client, bucket)
      client.list_objects_v2(bucket:).contents.each do |obj|
        client.delete_object(bucket:, key: obj.key)
      end
      client.delete_bucket(bucket:)
    rescue Aws::S3::Errors::NoSuchBucket
      nil
    end

    it 'creates bucket, puts object, gets object, deletes' do
      bucket = "spec-#{SecureRandom.hex(6)}"
      key = 'hello.txt'

      create_bucket(client, bucket)
      client.put_object(bucket:, key:, body: 'hello')
      result = client.get_object(bucket:, key:)

      expect(result.body.read).to eq('hello')
    ensure
      delete_bucket(client, bucket)
    end

    it 'uploads 1MB file successfully' do
      bucket = "spec-#{SecureRandom.hex(6)}"
      key = 'large.bin'
      file = Tempfile.new('s3-large')
      file.write('a' * (1024 * 1024))
      file.rewind

      create_bucket(client, bucket)
      client.put_object(bucket:, key:, body: file)
      result = client.get_object(bucket:, key:)

      expect(result.body.read.bytesize).to eq(1024 * 1024)
    ensure
      file&.close
      file&.unlink
      delete_bucket(client, bucket)
    end

    it 'handles 5 parallel PutObject calls' do
      bucket = "spec-#{SecureRandom.hex(6)}"
      create_bucket(client, bucket)

      Async do |task|
        tasks = 5.times.map do |index|
          task.async do
            client.put_object(bucket:, key: "obj-#{index}", body: "data-#{index}")
          end
        end
        tasks.map(&:wait)
      end.wait

      objects = client.list_objects_v2(bucket:).contents
      expect(objects.map(&:key)).to match_array((0..4).map { |i| "obj-#{i}" })
    ensure
      delete_bucket(client, bucket)
    end

    it 'round-trips binary data without corruption' do
      bucket = "spec-#{SecureRandom.hex(6)}"
      key = 'binary.bin'
      payload = Random.bytes(1024)

      create_bucket(client, bucket)
      client.put_object(bucket:, key:, body: payload)
      result = client.get_object(bucket:, key:)

      body = result.body.read
      expect(body.b).to eq(payload)
    ensure
      delete_bucket(client, bucket)
    end
  end
end
