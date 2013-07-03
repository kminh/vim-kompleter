" vim-kompleter - Smart keyword completion for Vim
" Maintainer:   Szymon Wrozynski
" Version:      0.1.1
"
" Installation:
" Place in ~/.vim/plugin/kompleter.vim or in case of Pathogen:
"
"     cd ~/.vim/bundle
"     git clone https://github.com/szw/vim-kompleter.git
"
" In case of Vundle:
"
"     Bundle "szw/vim-kompleter"
"
" License:
" Copyright (c) 2013 Szymon Wrozynski and Contributors.
" Distributed under the same terms as Vim itself.
" See :help license
"
" Usage:
" help :kompleter
" https://github.com/szw/vim-kompleter/blob/master/README.md

if exists("g:loaded_kompleter") || &cp || v:version < 700 || !has("ruby")
  finish
endif

let g:loaded_kompleter = 1

if !exists('g:kompleter_fuzzy_search')
  let g:kompleter_fuzzy_search = 0
endif

" Set to 0 disable asynchronous mode (using forking).
if !exists('g:kompleter_async_mode')
  let g:kompleter_async_mode = 1
endif

" 0 - case insensitive
" 1 - case sensitive
" 2 - smart case sensitive (see :help 'smartcase')
if !exists('g:kompleter_case_sensitive')
  let g:kompleter_case_sensitive = 1
endif

au VimEnter * call s:startup()
au VimLeave * call s:cleanup()
au BufEnter,BufLeave * call s:process_keywords()

fun! s:process_keywords()
  let &completefunc = 'kompleter#Complete'
  let &l:completefunc = 'kompleter#Complete'
  ruby KOMPLETER.process_all
endfun

fun! s:cleanup()
  ruby KOMPLETER.stop_data_server
endfun

fun! s:startup()
  ruby KOMPLETER.start_data_server
endfun

fun! kompleter#Complete(find_start_column, base)
  if a:find_start_column
    ruby VIM.command("return #{KOMPLETER.find_start_column}")
  else
    ruby VIM.command("return [#{KOMPLETER.complete(VIM.evaluate("a:base")).map { |c| "{ 'word': '#{c}', 'dup': 1 }" }.join(", ") }]")
  endif
endfun

ruby << EOF
require "drb/drb"

if RUBY_VERSION.to_f < 1.9
  class String
    def byte_length
      length
    end
  end
else
  class String
    def byte_length
      bytes.to_a.count
    end
  end
end

module Kompleter
  MIN_KEYWORD_SIZE = 3
  MAX_COMPLETIONS = 10
  DISTANCE_RANGE = 5000

  TAG_REGEX = /^([^\t\n\r]+)\t([^\t\n\r]+)\t.*?language:([^\t\n\r]+).*?$/u
  KEYWORD_REGEX = (RUBY_VERSION.to_f < 1.9) ? /[\w]+/u : /[_[:alnum:]]+/u

  FUZZY_SEARCH = VIM.evaluate("g:kompleter_fuzzy_search")
  CASE_SENSITIVE = VIM.evaluate("g:kompleter_case_sensitive")
  ASYNC_MODE = VIM.evaluate("g:kompleter_async_mode") != 0

  module KeywordParser
    # TODO check if filenames are correctly recognized under Windows
    def parse_tags(filename)
      keywords = Hash.new(0)

      File.open(filename).each_line do |line|
        match = TAG_REGEX.match(line)
        keywords[match[1]] += 1 if match && match[1].length >= MIN_KEYWORD_SIZE
      end

      keywords
    end

    def parse_text(text)
      keywords = Hash.new(0)
      text.scan(KEYWORD_REGEX).each { |keyword| keywords[keyword] += 1 if keyword.length >= MIN_KEYWORD_SIZE }
      keywords
    end
  end

  class DataServer
    include KeywordParser

    def initialize
      @data_id = 0
      @data = {}
      @data_mutex = Mutex.new
      @threads = {}
      @threads_mutex = Mutex.new
    end

    def add_text_async(text)
      data_id = next_data_id

      @threads[data_id] = Thread.new(text, data_id) do |t, did|
        keywords = parse_text(t)
        @data_mutex.synchronize { @data[did] = keywords }
        @threads_mutex.synchronize { @threads.delete(did) }
      end

      data_id
    end

    def add_tags_async(filename)
      data_id = next_data_id

      @threads[data_id] = Thread.new(filename, data_id) do |fname, did|
        keywords = parse_tags(fname)
        @data_mutex.synchronize { @data[did] = keywords }
        @threads_mutex.synchronize { @threads.delete(did) }
      end

      data_id
    end

    def get_data(data_id)
      return unless @data_mutex.try_lock
      data = @data.delete(data_id)
      @data_mutex.unlock
      data
    end

    def stop
      @threads_mutex.lock
      threads = @threads.dup
      @threads_mutex.unlock
      threads.each { |t| t.join }
      DRb.stop_service
    end

    def ready?
      true
    end

    private

    def next_data_id
      @data_id += 1
    end
  end

  class Repository
    include KeywordParser

    attr_reader :repository

    def initialize(kompleter)
      @kompleter = kompleter
      @repository = {}
    end

    def data_server
      @kompleter.data_server
    end

    def lookup(query)
      candidates = Hash.new(0)

      repository.each do |key, keywords|
        if keywords.is_a?(Fixnum)
          keywords = data_server.get_data(keywords)
          next unless keywords
          repository[key] = keywords
        end
        words = query ? keywords.keys.find_all { |word| query =~ word } : keywords.keys
        words.each { |word| candidates[word] += keywords[word] }
      end

      candidates.keys.sort { |a, b| candidates[b] <=> candidates[a] }
    end

    def try_clean_unused(key)
      return true unless repository[key].is_a?(Fixnum)
      !data_server.get_data(repository[key]).nil?
    end
  end

  class BufferRepository < Repository
    def add(number, text)
      return unless try_clean_unused(number)
      repository[number] = ASYNC_MODE ? data_server.add_text_async(text) : parse_text(text)
    end
  end

  class TagsRepository < Repository
    def add(tags_file)
      return unless try_clean_unused(tags_file)
      repository[tags_file] = ASYNC_MODE ? data_server.add_tags_async(tags_file) : parse_tags(tags_file)
    end
  end

  class Kompleter
    attr_reader :buffer_repository, :buffer_ticks, :tags_repository, :tags_mtimes, :data_server, :server_pid, :start_column, :real_start_column

    def initialize
      @buffer_repository = BufferRepository.new(self)
      @buffer_ticks = {}
      @tags_repository = TagsRepository.new(self)
      @tags_mtimes = Hash.new(0)
    end

    def process_current_buffer
      return if ASYNC_MODE && !server_pid

      buffer = VIM::Buffer.current
      tick = VIM.evaluate("b:changedtick")

      return if buffer_ticks[buffer.number] == tick

      buffer_ticks[buffer.number] = tick
      buffer_text = ""

      (1..buffer.count).each { |n| buffer_text << "#{buffer[n]}\n" }

      buffer_repository.add(buffer.number, buffer_text)
    end

    def process_tagfiles
      return if ASYNC_MODE && !server_pid

      tag_files = VIM.evaluate("tagfiles()")

      tag_files.each do |file|
        if File.exists?(file)
          mtime = File.mtime(file).to_i
          if tags_mtimes[file] < mtime
            tags_mtimes[file] = mtime
            tags_repository.add(file)
          end
        end
      end
    end

    def process_all
      process_current_buffer
      process_tagfiles
    end

    def stop_data_server
      return unless ASYNC_MODE && server_pid
      pid = server_pid
      @server_pid = nil
      data_server.stop
      Process.wait(pid)
      DRb.stop_service
    end

    def start_data_server
      return unless ASYNC_MODE && !server_pid
      DRb.start_service

      tcp_server = TCPServer.new("127.0.0.1", 0)
      port = tcp_server.addr[1]
      tcp_server.close

      pid = fork do
        DRb.start_service("druby://localhost:#{port}", DataServer.new)
        DRb.thread.join
        exit(0)
      end

      @data_server = DRbObject.new_with_uri("druby://localhost:#{port}")

      ticks = 0

      begin
        sleep 0.01
        @server_pid = pid if @data_server.ready?
      rescue DRb::DRbConnError
        retry if (ticks += 1) < 500

        Process.kill("KILL", pid)
        Process.wait(pid)

        ::Kompleter.send(:remove_const, :ASYNC_MODE)
        ::Kompleter.const_set(:ASYNC_MODE, false)

        msg = "Kompleter error: Cannot connect to the DRuby server at port #{port} in sensible time (over 5s). \n" \
              "Please restart Vim and try again. If the problem persists please open a new Github issue at \n" \
              "https://github.com/szw/vim-kompleter/issues. ASYNC MODE has been disabled for this session."

        VIM.command("echohl ErrorMsg")
        VIM.command("echo '#{msg}'")
        VIM.command("echohl None")
      end

      process_all
    end

    def find_start_column
      start_column = VIM::Window.current.cursor[1]
      line = VIM::Buffer.current.line.split(//u)
      counter = 0
      real_start_column = 0

      line.each do |letter|
        break if counter >= start_column
        counter += letter.byte_length
        real_start_column += 1
      end

      while (start_column > 0) && (real_start_column > 0) && ((line[real_start_column - 1] =~ KEYWORD_REGEX) == 0)
        real_start_column -= 1
        start_column -= line[real_start_column].byte_length
      end

      @real_start_column = real_start_column
      @start_column = start_column
    end

    def complete(query)
      buffer = VIM::Buffer.current
      row = VIM::Window.current.cursor[0]
      column = (RUBY_VERSION.to_f < 1.9) ? start_column : real_start_column

      cursor = 0
      text = ""

      (1..buffer.count).each do |n|
        line = "#{buffer[n]}\n"
        text << line

        if row > n
          cursor += line.length
        elsif row == n
          cursor += column
        end
      end

      if cursor > DISTANCE_RANGE
        text = text[(cursor - DISTANCE_RANGE)..-1]
        cursor = DISTANCE_RANGE
      end

      if text.length > (cursor + DISTANCE_RANGE)
        text = text[0, cursor + DISTANCE_RANGE]
      end

      keywords = Hash.new { |hash, key| hash[key] = Array.new }
      count = 0

      text.to_enum(:scan, KEYWORD_REGEX).each do |m|
        if m.length >= MIN_KEYWORD_SIZE
          keywords[m] << $`.size
          count += 1
        end
      end

      # convert to string in case of Fixnum, e.g. after 10<C-x><C-u> and force UTF-8 for Ruby >= 1.9
      query = (RUBY_VERSION.to_f < 1.9) ? query.to_s : query.to_s.force_encoding("UTF-8")

      if query.length > 0
        case_sensitive = (CASE_SENSITIVE == 2) ? !(query =~ /[[:upper:]]+/u).nil? : (CASE_SENSITIVE > 0)
        query = query.split(//u).join(".*?") if FUZZY_SEARCH > 0
        query = case_sensitive ? /^#{query}/u : /^#{query}/ui
        candidates_from_current_buffer = keywords.keys.find_all { |keyword| query =~ keyword }
      else
        query = nil
        candidates_from_current_buffer = keywords.keys
      end

      distances = {}

      candidates_from_current_buffer.each do |candidate|
        distance = keywords[candidate].map { |pos| (cursor - pos).abs }.min
        distance -= distance * (keywords[candidate].count / count.to_f)
        distances[candidate] = distance
      end

      candidates = candidates_from_current_buffer.sort { |a, b| distances[a] <=> distances[b] }

      if candidates.count >= MAX_COMPLETIONS
        return candidates[0, MAX_COMPLETIONS]
      else
        buffer_repository.lookup(query).each do |buffer_candidate|
          candidates << buffer_candidate unless candidates.include?(buffer_candidate)
          return candidates if candidates.count == MAX_COMPLETIONS
        end

        tags_repository.lookup(query).each do |tags_candidate|
          candidates << tags_candidate unless candidates.include?(tags_candidate)
          return candidates if candidates.count == MAX_COMPLETIONS
        end
      end

      candidates
    end
  end
end

KOMPLETER = Kompleter::Kompleter.new
EOF
