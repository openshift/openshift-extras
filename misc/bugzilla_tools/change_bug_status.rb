require 'rubygems'
require 'json'
require 'optparse'
require 'open-uri'

if __FILE__ == $PROGRAM_NAME
   
   #Check to see if the python-bugzilla tool is installed
   bugzilla_install = `rpm -q python-bugzilla`
   if(!bugzilla_install)
      puts "Please install the python-bugzilla tool to use this script!"
      exit(1)
   end  
 
   #Parse options
   options = {}
   optparse = OptionParser.new do |opts|
      opts.on('-m', '--move OPT', ["ON_QA", "MODIFIED"], "Move the bug status to either ON_QA or MODIFIED") do |s|
         options[:status] = s
      end
   end

   abort = false
   begin
      #If the options are parse incorrectly fail
      optparse.parse!
   rescue
      abort = true
   end

   #Parse bug ids
   ids = ""
   errorIds = []
   ARGV.each do |id|
      begin 
         Integer(id)
         ids << id << " " 
      rescue 
         errorIds << id 
      end
   end

   #Check that required parameters were found
   unless [:status] && ARGV.size > 0 && !abort
      puts "Usage: change_bug_status.rb -m <MODIFIED|ON_QA> <BUG_IDS_TO_MOVE>"
      exit(1)
   end


   #Notify user of not integer bugs and give option to abort
   if(errorIds.size > 0)
      print "The following ids are not integers: "
      errorIds.each do |id|
         print id + " "
      end
      puts ""

      token = ""
      while(token.casecmp('Y') != 0)
         print "Do you wish to continue with the other bug ids (Y/N): "
         token = $stdin.gets.chomp
         if(token.casecmp('N') == 0) then
            exit(0)
         end
      end
   end 
    
   #Get username for bugzilla script
   print "Username: "
   user_name = $stdin.gets.chomp
 
   #Update bugs
   `bugzilla --user=#{user_name} modify #{ids} -s #{options[:status]}`
end  
