# frozen_string_literal: true

# A minimal S3-compatible endpoint, enough for the calls UNLOAD makes and for a
# reader to fetch what it wrote. Keeps `rake test` offline -- the real thing is
# minio, which speaks the same subset.
#
# Requests arrive path-style (`/bucket/key`), which is what the SDK sends when
# `force_path_style` is set. Signatures are not verified.
class FakeS3
  def initialize
    @objects = {}
    @buckets = {}
    @mutex = Mutex.new
  end

  def objects
    @mutex.synchronize { @objects.dup }
  end

  def object(bucket, key)
    @mutex.synchronize { @objects["#{bucket}/#{key}"] }
  end

  def keys(bucket)
    prefix = "#{bucket}/"
    @mutex.synchronize { @objects.keys.select { |name| name.start_with?(prefix) }.map { |n| n.delete_prefix(prefix) } }
  end

  def call(env)
    bucket, _, key = env["PATH_INFO"].to_s.delete_prefix("/").partition("/")
    return [400, {}, ["missing bucket"]] if bucket.empty?

    case [env["REQUEST_METHOD"], key.empty?]
    when %w[HEAD].push(true) then head_bucket(bucket)
    when %w[PUT].push(true) then create_bucket(bucket)
    when %w[PUT].push(false) then put_object(bucket, key, env)
    when %w[GET].push(false) then get_object(bucket, key)
    when %w[HEAD].push(false) then head_object(bucket, key)
    else [405, {}, ["unsupported"]]
    end
  end

  private

  def head_bucket(bucket)
    @mutex.synchronize { @buckets.key?(bucket) } ? [200, {}, []] : [404, {}, []]
  end

  def create_bucket(bucket)
    @mutex.synchronize { @buckets[bucket] = true }
    [200, { "content-type" => "application/xml" }, []]
  end

  def put_object(bucket, key, env)
    body = env["rack.input"].read.to_s.b
    @mutex.synchronize do
      @buckets[bucket] = true
      @objects["#{bucket}/#{key}"] = body
    end
    [200, { "etag" => %("#{Digest::MD5.hexdigest(body)}") }, []]
  end

  def get_object(bucket, key)
    body = object(bucket, key) or return not_found
    [200, { "content-type" => "application/octet-stream", "content-length" => body.bytesize.to_s }, [body]]
  end

  def head_object(bucket, key)
    body = object(bucket, key) or return [404, {}, []]
    [200, { "content-length" => body.bytesize.to_s }, []]
  end

  def not_found
    [404, { "content-type" => "application/xml" },
     ["<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code></Error>"]]
  end
end
