module Bluepill
  module ProcessJournal
    extend self

    class << self
      attr_reader :logger

      def logger=(new_logger)
        @logger ||= new_logger
      end
    end

    def skip_pid?(pid)
      !pid.is_a?(Integer) || (-1..1).include?(pid)
    end

    # atomic operation on POSIX filesystems, since
    # f.flock(File::LOCK_SH) is not available on all platforms
    def acquire_atomic_fs_lock(name)
      times = 0
      name += '.lock'
      Dir.mkdir name, 0700
      logger.debug("Acquired lock #{name}")
      yield
    rescue Errno::EEXIST
      times += 1
      logger.debug("Waiting for lock #{name}")
      sleep 1
      unless times >= 10
        retry
      else
        logger.info("Timeout waiting for lock #{name}")
        raise "Timeout waiting for lock #{name}"
      end
    ensure
      clear_atomic_fs_lock(name)
    end

    def clear_all_atomic_fs_locks
      Dir['.*.lock'].each do |f|
        f.delete if f.directory?
      end
    end

    def journal_filename(journal_name)
      ".bluepill_pids_journal.#{journal_name}"
    end

    def journal(filename)
      logger.debug("journal PWD=#{Dir.pwd}")
      result = File.open(filename, 'r').readlines.map(&:to_i).reject {|pid| skip_pid?(pid)}
      logger.debug("journal = #{result.join(' ')}")
      result
    rescue Errno::ENOENT
      []
    end

    def clear_atomic_fs_lock(name)
      if File.directory?(name)
        Dir.rmdir(name)
        logger.debug("Cleared lock #{name}")
      end
    end

    def kill_all_from_all_journals
      Dir[".bluepill_pids_journal.*"].map {|x| x.sub(/^\.bluepill_pids_journal\./,"") }.each do |journal_name|
        kill_all_from_journal(journal_name)
      end
    end

    def kill_all_from_journal(journal_name)
      filename = journal_filename(journal_name)
      j = journal(filename)
      if j.length > 0
        acquire_atomic_fs_lock(filename) do
          j.each do |pid|
            begin
              ::Process.kill('TERM', pid)
              logger.info("Termed old process #{pid}")
            rescue Errno::ESRCH
              logger.info("Unable to term missing process #{pid}")
            end
          end

          if j.select { |pid| System.pid_alive?(pid) }.length > 1
            sleep(1)
            j.each do |pid|
              begin
                ::Process.kill('KILL', pid)
                logger.info("Killed old process #{pid}")
              rescue Errno::ESRCH
                logger.info("Unable to kill missing process #{pid}")
              end
            end
          end
          File.delete(filename) # reset journal
          logger.debug('Journal cleanup completed')
        end
      else
        logger.debug('No previous process journal - Skipping cleanup')
      end
    end

    def append_pid_to_journal(journal_name, pid)
      if skip_pid?(pid)
        logger.info("Skipping invalid pid #{pid} (class #{pid.class})")
        return
      end

      filename = journal_filename(journal_name)
      acquire_atomic_fs_lock(filename) do
        unless journal(filename).include?(pid)
          logger.debug("Saving pid #{pid} to process journal #{journal_name}")
          File.open(filename, 'a+', 0600) { |f| f.puts(pid) }
          logger.info("Saved pid #{pid} to process journal #{journal_name}")
        else
          logger.debug("Skipping duplicate pid #{pid} already in journal #{journal_name}")
        end
      end
    end
  end
end
