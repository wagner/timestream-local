# frozen_string_literal: true

require "securerandom"

require_relative "timestream_local/errors"
require_relative "timestream_local/types"
require_relative "timestream_local/query/time_series"
require_relative "timestream_local/query/functions"
require_relative "timestream_local/query/rewriter"
require_relative "timestream_local/query/timestamp_literals"
require_relative "timestream_local/query/unload"
require_relative "timestream_local/object_store"
require_relative "timestream_local/store"
require_relative "timestream_local/write_api"
require_relative "timestream_local/query_api"
require_relative "timestream_local/scheduled_query_api"
require_relative "timestream_local/web_ui"
require_relative "timestream_local/server"

module TimestreamLocal
  VERSION = "1.1.0"

  module_function

  def build(path: ENV.fetch("TIMESTREAM_LOCAL_DATA", ":memory:"),
            region: ENV.fetch("TIMESTREAM_LOCAL_REGION", "us-east-1"),
            account_id: ENV.fetch("TIMESTREAM_LOCAL_ACCOUNT_ID", "000000000000"))
    Server.new(Store.new(path: path, region: region, account_id: account_id))
  end
end
