# 
#  svn_log_parser.rb
#  Subversion.tmbundle
#  
#  Low-level:
# 	LogParser.parse_path(path) {|hash_for one_log_entry| ... }
# 	LogParser.parse(string_or_IO) {|hash_for one_log_entry| ... }
#
#  High-level:
#  	Subversion.view_revision(path)
#
#  Created by Chris Thomas on 2006-12-30.
#  Copyright 2006 Chris Thomas. All rights reserved.
# 

require 'rexml/document'
require 'time'
require 'uri'
require 'yaml'

require "#{ENV["TM_SUPPORT_PATH"]}/lib/plist"
require "#{ENV["TM_SUPPORT_PATH"]}/lib/dialog"
require "#{ENV["TM_SUPPORT_PATH"]}/lib/progress"
require "#{ENV["TM_SUPPORT_PATH"]}/lib/escape"

ListNib = File.dirname(__FILE__) + "/nibs/RevisionSelector.nib"

module Subversion
	
	def self.svn_cmd(args)
		result_text = %x{"#{ENV['TM_SVN']||'svn'}" #{args}}
		raise if $CHILD_STATUS != 0		
		result_text
	end

	def self.svn_cmd_popen(args)
		command = %Q{"#{ENV['TM_SVN']||'svn'}" #{args}}
		if block_given? then
			IO.popen(command) {|f| f.each_line {|line| yield line}}
		else
			IO.popen(command)
		end
	end
	
	def self.human_readable_mktemp(filename, rev)
		extname = File.extname(filename)
		filename = File.basename(filename)
		# TODO: Make sure the filename can fit in 255 characters, the limit on HFS+ volumes.
		
		"#{filename.sub(extname, '')}-r#{rev}#{extname}"
	end

	def self.view_revision(path)
		# Get the desired revision number
		revisions = choose_revision(path, "Choose a revision to view", :multiple)
		return if revisions.nil?

		files						= []

		TextMate.call_with_progress(:title => "View Revision",
										          :summary => "Retrieving revision data…",
															:details => "#{File.basename(path)}") do |dialog|
			revisions.each do |revision|
				# Get the file at the desired revision
				dialog.parameters = {'summary' => "Retrieving revision #{revision}…"}
				
				temp_name = '/tmp/' + human_readable_mktemp(path, revision)
				svn_cmd("cat -r#{revision} #{e_sh(path)} > #{temp_name}")
				files << temp_name
		  end
		end
		
		# Open the files in TextMate and delete them on close
		### mate -w doesn't work on multiple files, so we'll do one file at a time...
		files.each do |file|
			fork do 
				%x{"#{ENV['TM_SUPPORT_PATH']}/bin/mate" -w #{e_sh(file)}}
				File.delete(file)
			end
		end
	end
	
	# on failure: returns nil
	def self.choose_revision(path, prompt, number_of_revisions = 1)
		escaped_path = e_sh(path)

		# Get the server name
		info = YAML::load(svn_cmd("info #{escaped_path}"))
		repository = info['Repository Root']
		uri = URI::parse(repository)

		# Display progress dialog
		log_data = ''
		
		# Show the log
		revision = 0
		TextMate::Dialog.dialog(:nib => ListNib,
														:center => true,
														:parameters => {'title' => "View revision of #{File.basename(path)}",'entries' => [], 'hideProgressIndicator' => false}) do |dialog|

			# Parse the log
			begin
				plist = []
				log_data = svn_cmd_popen("log --xml #{escaped_path}")
				
				Subversion::LogParser.parse(log_data) do |hash|
					plist << hash
					# update every ten entries (? may do better with a timeout)
					if (plist.size % 10) == 0 then
						dialog.parameters = {'entries' => plist}
					end 
				end
				dialog.parameters = {'entries' => plist, 'hideProgressIndicator' => true}
				
				if plist.size == 0
					TextMate::Dialog.alert(:warning, "No revisions of file “#{path}” found", "Either there’s only one revision of this file, and you already have it, or this file was never added to the repository in the first place, or I can’t read the contents of the log for reasons unknown.")
				end
			rescue REXML::ParseException => exception
				TextMate::Dialog.alert(:warning, "Could not parse log data for “#{path}”", "This may be a bug. Error: #{error}.")
			end
			
			dialog.wait_for_input do |params|
				revision = params['returnArgument']
				STDERR.puts params['returnButton']
#				STDERR.puts "Want:#{number_of_revisions} got:#{revision.length}"
				button_clicked = params['returnButton']

				if (button_clicked != nil) and (button_clicked == 'Cancel')
					false # exit
				else
					unless (number_of_revisions == :multiple) or (revision.length == number_of_revisions) then
						TextMate::Dialog.alert(:warning, "Please select #{number_of_revisions} revision#{number_of_revisions == 1 ? '' : 's'}.", "So far, you have selected #{revision.length} revision#{revision.length == 1 ? '' : 's'}.")
						true # continue
					else
						false # exit
					end
				end
			end

#			dialog.close
		end
		
		# Return the revision number or nil
		revision = nil if revision == 0
		revision
	end
	
	# Streaming 'svn log --xml' output parser.
	class LogParser
		
		# path may be a Subversion working copy path or a repository URL
		def LogParser.parse_path(path, &block)
			path = File.expand_path(path)
			log_cmd = %Q{"#{ENV['TM_SVN']||svn}" log --xml "#{path}"}

			IO.popen(log_cmd, "r") do |io|
				LogParser.parse(io) do |hash|
					block.call(hash)
				end
			end # IO.popen
		end
		
		# source may be a string or an IO subclass
		def LogParser.parse(source, &block)
			listener = LogParser.new(&block)
			
			# TODO: remove and report any text prior to the XML data
			REXML::Document.parse_stream(source, listener)
		end

		# This listener makes no attempt to validate according to schema.
		# The SVN log node names are unique and nonrecursive,
		# so this shouldn't be an issue. But it would be nice as a sanity check.
		def initialize(&block)
			@callback_block = block
		end
	
		def xmldecl(*ignored)
		end
	
		def tag_start(name, attributes)
			case name
			when 'logentry'
				revision = attributes['revision']
				@current_log = {'rev' => revision.to_i}
			end
		end

		def tag_end(name)
			case name
			when 'author','msg'
				@current_log[name] = @text
			when 'date'
				@current_log[name] = Time.xmlschema(@text)
			when 'logentry'
				@callback_block.call(@current_log)
			end
		end
	
		def text(text)
			@text = text
		end

	end # class LogParser
end # module Subversion

if __FILE__ == $0
	
#	test_path = "~/TestRepo/TestFiles"
# REXML thinks this is perfectly acceptable XML input.
#I'm pretty sure it's not, but I haven't read the spec in the last four years.
	Subversion::LogParser.parse(%Q{Lorem ipsum dolor sit amet, consectetur adipisicing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam,
		quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat
		. Duis aute irure dolor in reprehenderit in voluptate velit esse
		 cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.
		}) do |hash|
		puts hash.inspect
	end

# It catches this and other angle-bracket problems, though.
	Subversion::LogParser.parse(%Q{<Lo> <lo> <lo> <.&&>>>><<<<<DFDFSFD<S<DF<D<F>DFWE242$>@$>@>$&&&&!!!>> dolor sit amet, consectetur adipisicing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam,
		quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat
		. Duis aute irure dolor in reprehenderit in voluptate velit esse
		 cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.
		}) do |hash|
		puts hash.inspect
	end
	
	# # plist
	# plist = []
	# Subversion::LogParser.parse_path(test_path) do |hash|
	# 	plist << hash
	# end
	# puts plist.to_plist
	
end
