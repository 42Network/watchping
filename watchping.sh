#!/bin/sh
#
# watchping - daemon to ping servers, take action if down (email/web/log). 
#	Stateful, only emails when something changes. Unix.
#
# 25-Jun-2003	ver 1.10
#
# USAGE: watchping [-vhES][-e addr][-s priority][-l logfile][-w website]
#                  [-t secs][-i infile | hosts ...]
#
#  eg,  watchping                     # Ping /etc/hosts hosts, email root.
#       watchping -e fred@nurk.com    # Email this address instead of root.
#       watchping mars phobos         # Ping these servers instead.
#       watchping -i prod.txt         # Read host list from prod.txt.
#	watchping -w hosts.html       # Generate website of host status.
#
# By default it pings servers listed in /etc/hosts, and both emails root and
# logs via syslog if a server goes down. The servers to ping can be configured
# in either a text file or arguments, and actions to take are options below.
# It has been written for Solaris and should work elsewhere with
# minor changes.
#
#	-h	Usage help.
#	-v	Verbose info on startup. Use until familiar with options.
#	-e	Email this address. By default it emails root.
#	-E	Don't send email.
#	-t	Seconds to sleep between pings. Default is 60.
#	-s	Use this "facility.priority" for syslog. By default it uses
#		the "priority" variable in the script below.
#	-S	Don't send messages to syslog. Default is to use syslog.
#	-w	Web site. Update this website with ping status (coloured).
#	-l	Log file. Append status messages here.
#	hosts	A list of hosts to ping. By default, the list is fetched from
#		hosts discovered in /etc/hosts (specified in the "hosts"
#		variable in the script).
#	-i	In list file. A text file containing the host list mentioned
#		above. Syntax is a list of hostnames and/or IPs. Useful if 
#		the host list grows to be large.
#
# The four actions are to email alerts, syslog alerts, log everything, and
# generate a website. A combination may be practical. For example, a startup
# script might run,
#
#	watchping -e sysadmin@mars -w /var/http/prod.html -i /etc/prod.txt &
#	watchping -e dbadmin@venus -w /var/http/db.html -i /etc/db.txt &
#
# Both of the above run in the background, check every 60 seconds, and send
# alerts to syslog. They will also email alerts to the address after "-e",
# they read host lists from the text files in /etc after the "-i" (here one
# may list production server names, the other database server names), and 
# they even update colour coded websites after the "-w" (red is bad, green is
# good, blue is unknown).
#
# COPYRIGHT: Copyright (c) 2003 Brendan Gregg.
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License
#  as published by the Free Software Foundation; either version 2
#  of the License, or (at your option) any later version. 
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details. 
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software Foundation, 
#  Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
#  (http://www.gnu.org/copyleft/gpl.html)
#
# 03-Jun-2003	Brendan Gregg	Created this.
# 25-Jun-2003	Brendan Gregg	Added event based code.
# 12-Jan-2014   Nathan Ellsworth	Modified to work with Linux


#
# --- Setup Vars and Subs ---
#
ping=/bin/ping		# Location of ping
timeout=2			# Default ping timeout, secs
retries=1           # Number of ping retries
PATH=/bin:$PATH
verbose=0			# setup defaults
addr="root"
email=1
priority="user.err"
syslog=1
hostsdb="/etc/hosts"		# if used
secs=60
logfile=""
website=""
infile=""
deadlast=""			# previous list of dead hosts

# usage - print the usage message
#
usage() {
	echo >&2 "USAGE: $0 [-vhES][-e addr][-s priority][-l logfile]
                   [-w website][-t secs][-i infile | hosts ...]
  eg,  $0                     # Ping /etc/hosts hosts, email root.
       $0 -e fred@nurk.com    # Email this address instead of root.
       $0 mars phobos         # Ping these servers instead.
       $0 -i prod.txt         # Read host list from prod.txt.
       $0 -w hosts.html       # Generate website of host status."
}

# logtext - append the input text to the file in $logfile.
#
logtext() {
	echo -e "-----\n$*" >> $logfile
}

# webtext - process the input text into a website and save to $website file.
#	If you know some HTML, the lines below can be customised to your
#	taste. (If this awk program was much longer, it should be perl).
#
webtext() {
	# This can be customised below.
(	echo "$*" | awk '
		NR == 1 { print "<HTML><HEAD><TITLE>WatchPing Report</TITLE>"
			  print "</HEAD><BODY BGCOLOR=\"#FFFFFF\">"
			  print "<H1>WatchPing Report, " $0 "</H1><HR><H2>"
		}
		NR > 1 { if ($0 ~ /is down/) {
			    print "<FONT COLOR=\"#FF0000\">" $0 "</FONT><BR>"
			 } else if ($0 ~ /unknown hostname/) {
			    print "<FONT COLOR=\"#0000AA\">" $0 "</FONT><BR>"
			 } else {
			    print "<FONT COLOR=\"#00AA00\">" $0 "</FONT><BR>"
			 }
		}
		END { print "</BODY></HTML>" }'
)	> $website
}

# emailsend - This reads from two variables,  $dead and $text, and emails
#	their contents to the $addr variable. If will generate a syslog 
#	error if the email can't be sent (if allowed to syslog).
#
emailsend() {
	mail $addr <<-END
	Subject: WatchPing Alert:$dead
	WatchPing Alert
	
	The following hosts failed to ping,
	$dead
	
	Output from all pings,

	$text
	END
	if [ $? -ne 0 -a $syslog -eq 1 ]; then
		logger -twatchping -p$syslog ERROR1: Emailing $addr
	fi
}

# syslogsend - sent a message to syslog
#
syslogsend() {
	logger -twatchping -p$syslog Hosts Down: $dead
}

#
# --- Parse Options ---
#
set -- `getopt vhESe:t:s:l:w:i: $*`
if [ $? -ne 0 ]; then
        usage
        exit 1
fi

while [ $# -ne 0 ]
do
	case "$1" in
	-v)	verbose=1 
		;;
	-h)	usage
		exit 0
		;;
	-E)	email=0
		;;
	-S)	syslog=0
		;;
	-e)	addr=$2
		shift
		;;
	-t)	secs=$2
		shift
		;;
	-s)	priority=$2
		shift
		;;
	-l)	logfile=$2
		touch $logfile
		if [ $? -ne 0 ]; then
		   echo >&2 "ERROR3: logfile $logfile, is not writable."
		   exit 2
		fi
		shift
		;;
	-w)	website=$2
		touch $website
		if [ $? -ne 0 ]; then
		   echo >&2 "ERROR4: website $website, is not writable."
		   exit 2
		fi
		shift
		;;
	-i)	infile=$2
		if [ ! -r $infile ]; then
		   echo >&2 "ERROR5: $infile, is not readable."
		   exit 2
		fi
		hosts=`cat $infile` 	# Use infile for list of hosts
		shift
		;;
	--)	shift
		break
		;;
	esac
	shift
done

if [ "$1" != "" ]; then			# hosts were on the command line
        hosts=$*
fi

if [ "$hosts" = "" ]; then		# or, fetch hosts from default
	if [ ! -r "$hostsdb" ]; then
	   echo >&2 "ERROR6: $hostsdb, is not readable."
	   exit 2
	fi
	hosts=`awk '/^[0-9]/ { print $1 }' $hostsdb`
fi


#
# --- Print Settings, if verbose ---
#
if [ $verbose -eq 1 ]; then
	echo "Running WatchPing..."
	echo "Sleep Interval: $secs secs"
	[ $email -eq 1 ] && echo "Email address: $addr"
	[ $syslog -eq 1 ] && echo "Syslog priority: $priority"
	[ "$logfile" != "" ] && echo "Logfile: $logfile"
	[ "$website" != "" ] && echo "Website: $website"
	echo "Checking Hosts:" $hosts
fi


#
# --- MAIN LOOP ---
#
while :
do
	error=0
	dead=""					# list of dead hosts
	text="`date`"				# output report

	#
	#  Ping hosts 
	#
	for host in $hosts
	do
		output=$($ping -q -c $retries -W $timeout $host 2>&1)
		if [ $? -ne 0 ]; then
			error=1
			dead="$dead $host"
		fi
#		[ $verbose -eq 1 ] && echo "$output"
		output2=$(echo "$output" | awk '
		   /PING/        { gsub("[():]",""); hostname=$2;ip=$3 } 
		   /packet/      { loss=$7 } 
		   /round-trip/  { split($4,t,"/"); time=t[3] } 
		   /bad address/ { gsub("\047",""); bad=$4 } 
		   END { if (bad)         { printf("%s unknown hostname\n",bad) } 
				 else if (time)   { printf("%s [%s] is up (time = %s ms)\n", hostname,ip,time) } 
				 else             { printf("%s [%s] is down\n", hostname,ip) }
			   }
		')
		
		text="${text}
 ${output2}"
	done

	#
	#  Process Actions 
	#
	[ $verbose -eq 1 ] && echo -e "-----\n$text"
	[ "$logfile" != "" ] && logtext "$text"
	[ "$website" != "" ] && webtext "$text"

	# These actions are triggered by a state change
	if [ "$dead" != "$deadlast" ]; then
		if [ $error -ne 0 ]; then
			[ $email -eq 1 ] && emailsend	   # hosts down email
			[ $syslog -eq 1 ] && syslogsend
		else
			dead=" (all ok!)"		   # (msg for email)
			[ $email -eq 1 ] && emailsend	   # all ok email
			[ $syslog -eq 1 ] && syslogsend
			dead=""
		fi
	fi

	deadlast="$dead"
	sleep $secs
done