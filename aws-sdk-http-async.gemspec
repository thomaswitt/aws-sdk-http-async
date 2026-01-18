Gem::Specification.new do |spec|
  spec.name = 'aws-sdk-http-async'
  spec.version = File.read(File.expand_path('VERSION', __dir__)).strip
  spec.summary = 'Async HTTP handler plugin for AWS SDK for Ruby'
  spec.description = 'Provides an async-http based send handler for aws-sdk-core.'
  spec.author = 'Thomas Witt'
  spec.homepage = 'https://github.com/thomaswitt/aws-sdk-http-async'
  spec.license = 'Apache-2.0'
  spec.require_paths = ['lib']
  spec.bindir = 'exe'
  spec.executables = ['async-rake']
  spec.files = Dir['LICENSE.txt', 'CHANGELOG.md', 'README.md', 'VERSION', 'lib/**/*.rb', 'exe/*']

  spec.add_dependency('aws-sdk-core', '>= 3.241.0')
  spec.add_dependency('async-http', '>= 0.94.0')

  spec.add_development_dependency('aws-sdk-dynamodb', '~> 1')
  spec.add_development_dependency('aws-sdk-s3', '~> 1')
  spec.add_development_dependency('brakeman', '~> 7.1')
  spec.add_development_dependency('bundler-audit', '~> 0.9')
  spec.add_development_dependency('rake', '~> 13.0')
  spec.add_development_dependency('rspec', '~> 3.13')
  spec.add_development_dependency('rubocop-rails', '~> 2.0')
  spec.add_development_dependency('rubocop-rails-omakase', '~> 1.0')
  spec.add_development_dependency('rubocop-rake', '~> 0.6')
  spec.add_development_dependency('rubocop-rspec', '~> 3.0')
  spec.add_development_dependency('rufo', '~> 0.18')
  spec.add_development_dependency('webmock', '~> 3.0')

  spec.metadata = {
    'source_code_uri' => 'https://github.com/thomaswitt/aws-sdk-http-async',
    'changelog_uri' => 'https://github.com/thomaswitt/aws-sdk-http-async/blob/main/CHANGELOG.md',
    'rubygems_mfa_required' => 'true',
  }

  spec.required_ruby_version = '>= 3.4.0'
end
