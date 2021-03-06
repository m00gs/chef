#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/config'
require 'chef/log'
require 'chef/resource/file'
require 'chef/mixin/checksum'
require 'chef/provider'
require 'etc'
require 'fileutils'
require 'chef/scan_access_control'
require 'chef/mixin/shell_out'

class Chef

  class Provider
    class File < Chef::Provider
      include Chef::Mixin::Checksum
      include Chef::Mixin::ShellOut

      def negative_complement(big)
        if big > 1073741823 # Fixnum max
          big -= (2**32) # diminished radix wrap to negative
        end
        big
      end

      def octal_mode(mode)
        ((mode.respond_to?(:oct) ? mode.oct : mode.to_i) & 007777)
      end

      private :negative_complement, :octal_mode

      def diff_current_from_content source_content
        result = nil
        Tempfile.open("chef-diff") do |file| 
          file.write source_content
          file.close 
          result = diff_current file.path
        end
        result
      end

      def diff_current source_path
        begin
 	  # Solaris diff doesn't support -N (treat missing files as empty) 
          # For compatibility we'll create a temp file if the file does not exist
          # and substitute it
	  unless ::File.exists?(source_path) 
	    altfile = Tempfile.new('chef-tempfile')
            source_path = altfile.path
          end
          # -u: Unified diff format
          result = shell_out("diff -u #{@current_resource.path} #{source_path}" )
          # diff will set a non-zero return code even when there's 
          # valid stdout results, if it encounters something unexpected
          # So as long as we have output, we'll show it.
          if not result.stdout.empty?
            val = result.stdout.split("\n")
            val.delete("\\ No newline at end of file")
            val
          elsif not result.stderr.empty?
            "Could not determine diff. Error: #{result.stderr}"
          else
            "(no diff)"
          end
        rescue Exception => e
          # Should *not* receive this, but in some circumstances it seems that 
          # an exception can be thrown even using shell_out instead of shell_out!
          "Could not determine diff. Error: #{e.message}"
        end
      end 

      def whyrun_supported?
        true
      end

      def load_current_resource
        @current_resource = Chef::Resource::File.new(@new_resource.name)
        @new_resource.path.gsub!(/\\/, "/") # for Windows
        @current_resource.path(@new_resource.path)
        if @new_resource.content && ::File.exist?(@new_resource.path)
          @current_resource.checksum(checksum(@new_resource.path))
        end
        setup_acl
      end
      
      def setup_acl
        @acl_scanner = ScanAccessControl.new(@new_resource, @current_resource)
        @acl_scanner.set_all!
      end

      def define_resource_requirements
        # this must be evaluated before whyrun messages are printed
        access_controls.requires_changes?

        requirements.assert(:create, :create_if_missing, :touch) do |a|
          # Make sure the parent dir exists, or else fail.
          # for why run, print a message explaining the potential error.
          parent_directory = ::File.dirname(@new_resource.path)

          a.assertion { ::File.directory?(parent_directory) }
          a.failure_message(Chef::Exceptions::EnclosingDirectoryDoesNotExist, "Parent directory #{parent_directory} does not exist.")
          a.whyrun("Assuming directory #{parent_directory} would have been created")
        end

        # Make sure the file is deletable if it exists. Otherwise, fail.
        requirements.assert(:delete) do |a|
          a.assertion do
            if ::File.exists?(@new_resource.path) 
              ::File.writable?(@new_resource.path)
            else
              true
            end
          end
          a.failure_message(Chef::Exceptions::InsufficientPermissions,"File #{@new_resource.path} exists but is not writable so it cannot be deleted")
        end
      end

      # Compare the content of a file.  Returns true if they are the same, false if they are not.
      def compare_content
        checksum(@current_resource.path) == new_resource_content_checksum
      end

      # Set the content of the file, assuming it is not set correctly already.
      def set_content
        unless compare_content
          description = []
          description << "update content in file #{@new_resource.path} from #{short_cksum(@current_resource.checksum)} to #{short_cksum(new_resource_content_checksum)}"
          description << diff_current_from_content(@new_resource.content) 
          converge_by(description) do
            backup @new_resource.path if ::File.exists?(@new_resource.path)
            ::File.open(@new_resource.path, "w") {|f| f.write @new_resource.content }
            Chef::Log.info("#{@new_resource} contents updated")
          end
        end
      end

      def action_create
        if !::File.exists?(@new_resource.path)
          description = []
          desc = "create new file #{@new_resource.path}"
          desc << " with content checksum #{short_cksum(new_resource_content_checksum)}" if new_resource.content
          description << desc
          description << diff_current_from_content(@new_resource.content) 
          converge_by(description) do
            ::File.open(@new_resource.path, "w+") {|f| f.write @new_resource.content }
            access_controls.set_all
            Chef::Log.info("#{@new_resource} created file #{@new_resource.path}")
          end
        else
          set_content unless @new_resource.content.nil?
          set_all_access_controls
        end
      end

      def set_all_access_controls
        if access_controls.requires_changes?
          converge_by(access_controls.describe_changes) do 
            access_controls.set_all
          end
        end
      end

      def action_create_if_missing
        if ::File.exists?(@new_resource.path)
          Chef::Log.debug("#{@new_resource} exists at #{@new_resource.path} taking no action.")
        else
          action_create
        end
      end

      def action_delete
        if ::File.exists?(@new_resource.path)
          converge_by("delete file #{@new_resource.path}") do 
            backup unless ::File.symlink?(@new_resource.path)
            ::File.delete(@new_resource.path)
            Chef::Log.info("#{@new_resource} deleted file at #{@new_resource.path}")
          end
        end
      end

      def action_touch
        action_create
        converge_by("update utime on file #{@new_resource.path}") do
          time = Time.now
          ::File.utime(time, time, @new_resource.path)
          Chef::Log.info("#{@new_resource} updated atime and mtime to #{time}")
        end
      end

      def backup(file=nil)
        file ||= @new_resource.path
        if @new_resource.backup != false && @new_resource.backup > 0 && ::File.exist?(file)
          time = Time.now
          savetime = time.strftime("%Y%m%d%H%M%S")
          backup_filename = "#{@new_resource.path}.chef-#{savetime}"
          backup_filename = backup_filename.sub(/^([A-Za-z]:)/, "") #strip drive letter on Windows
          # if :file_backup_path is nil, we fallback to the old behavior of
          # keeping the backup in the same directory. We also need to to_s it
          # so we don't get a type error around implicit to_str conversions.
          prefix = Chef::Config[:file_backup_path].to_s
          backup_path = ::File.join(prefix, backup_filename)
          FileUtils.mkdir_p(::File.dirname(backup_path)) if Chef::Config[:file_backup_path]
          FileUtils.cp(file, backup_path, :preserve => true)
          Chef::Log.info("#{@new_resource} backed up to #{backup_path}")

          # Clean up after the number of backups
          slice_number = @new_resource.backup
          backup_files = Dir[::File.join(prefix, ".#{@new_resource.path}.chef-*")].sort { |a,b| b <=> a }
          if backup_files.length >= @new_resource.backup
            remainder = backup_files.slice(slice_number..-1)
            remainder.each do |backup_to_delete|
              FileUtils.rm(backup_to_delete)
              Chef::Log.info("#{@new_resource} removed backup at #{backup_to_delete}")
            end
          end
        end
      end

      def deploy_tempfile
        Tempfile.open(::File.basename(@new_resource.name)) do |tempfile|
          yield tempfile

          temp_res = Chef::Resource::CookbookFile.new(@new_resource.name)
          temp_res.path(tempfile.path)
          ac = Chef::FileAccessControl.new(temp_res, @new_resource, self)
          ac.set_all!
          FileUtils.mv(tempfile.path, @new_resource.path)
        end
      end

      private

      def short_cksum(checksum)
        return "none" if checksum.nil?
        checksum.slice(0,6)
      end

      def new_resource_content_checksum
        @new_resource.content && Digest::SHA2.hexdigest(@new_resource.content)
      end
    end
  end
end
