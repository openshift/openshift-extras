Bugzilla Tools
==============

This directory is for holding Bugzilla scripts and tools that can be used to help speed up the development process.


Change_Bug_Status.rb
--------------------

This script can be used to automatically update Bugzilla bugs that need to be moved to Modified/ON_QA depending on the current state in development. 
Usage: "ruby change_bug_status.rb -m &lt;MODFIED | ON_QA&gt; &lt;BUG_IDS_TO_MOVE&gt;"
