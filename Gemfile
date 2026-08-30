source "https://rubygems.org"

gem "puma"
gem "rack"
gem "sqlite3"
# XXH64 for the xxhash64() SQL function. The same gem a Ruby client hashes
# with, so the SQL and Ruby sides agree by construction rather than by
# coincidence.
gem "xxhash"
# Only loaded when UNLOAD is used; the server boots and runs without an S3.
gem "aws-sdk-s3"
# S3 speaks REST-XML and aws-sdk-s3 needs a parser; rexml stopped being a
# bundled default gem, so it has to be asked for explicitly.
gem "rexml"

group :development, :test do
  gem "aws-sdk-timestreamquery"
  gem "aws-sdk-timestreamwrite"
  gem "minitest"
  gem "rake"
end
