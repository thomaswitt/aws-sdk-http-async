require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'shellwords'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc 'Reformat files (Rufo + RuboCop autocorrect)'
task :formatter, [:file_list] do |_, args|
  files = Shellwords.split(args[:file_list].to_s)
  puts "Processing files: #{files.join(', ')}" if files.any?

  $stderr.sync = true

  $stderr.print 'Autocorrect: rufo (pre-rubocop) ...'
  FormatterTasks.run_rufo(files)
  $stderr.puts ' done'

  $stderr.print 'Autocorrect: rubocop ...'
  FormatterTasks.run_rubocop_autocorrect(files)
  $stderr.puts ' done'

  $stderr.print 'Autocorrect: rufo (post-rubocop) ...'
  FormatterTasks.run_rufo(files)
  $stderr.puts ' done'

  FormatterTasks.verify_rufo_idempotent(files)
end

namespace :rufo do
  desc 'Check Rufo formatting without modifying files'
  task :check, [:file_list] do |_, args|
    files = Shellwords.split(args[:file_list].to_s)
    success = FormatterTasks.check_rufo(files)
    abort('Rufo formatting check failed! Run "rake formatter" to fix.') unless success
  end
end

module FormatterTasks
  module_function

  def run_rufo(files)
    targets = rufo_targets(files)
    if targets == :all
      system('bundle exec rufo . --loglevel=silent >/dev/null')
    elsif targets.any?
      escaped = targets.map { Shellwords.shellescape(it) }
      system("bundle exec rufo #{escaped.join(' ')} --loglevel=silent >/dev/null")
    end
  end

  def run_rubocop_autocorrect(files)
    if files.empty?
      success = system('bundle exec rubocop --no-server --format quiet --autocorrect >/dev/null')
    else
      escaped = files.map { Shellwords.shellescape(it) }
      success = system("bundle exec rubocop --no-server --force-exclusion --format quiet --autocorrect #{escaped.join(' ')} >/dev/null")
    end
    abort('RuboCop autocorrect failed.') unless success
  end

  def verify_rufo_idempotent(files)
    targets = rufo_targets(files)
    cmd = if targets == :all
        'bundle exec rufo --check . --loglevel=silent >/dev/null'
      elsif targets.any?
        escaped = targets.map { Shellwords.shellescape(it) }
        "bundle exec rufo --check #{escaped.join(' ')} --loglevel=silent >/dev/null"
      end
    return if cmd.nil?

    abort('Formatter left files non-idempotent.') unless system(cmd)
  end

  def check_rufo(files)
    targets = rufo_targets(files)
    if targets == :all
      system('bundle exec rufo --check . --loglevel=silent')
    elsif targets.any?
      escaped = targets.map { Shellwords.shellescape(it) }
      system("bundle exec rufo --check #{escaped.join(' ')} --loglevel=silent")
    else
      true
    end
  end

  def rufo_targets(files)
    return :all if files.nil? || files.empty?

    files.map { it.to_s.strip }.reject(&:empty?).select { File.exist?(it) }.uniq
  end
end
