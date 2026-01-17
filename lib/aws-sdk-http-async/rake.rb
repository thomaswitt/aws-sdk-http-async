require 'async'
require 'rake'
require 'aws-sdk-http-async'
require 'async/aws/rake_patch'

Rake::Application.prepend(Async::Aws::RakePatch) unless Rake::Application < Async::Aws::RakePatch
