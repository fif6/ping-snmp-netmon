#!/usr/bin/perl

BEGIN {
	use FindBin '$Bin';
	unshift(@INC, "$Bin/modules"); # add custom Modules path at the first of position in @INC
};


BEGIN {
    use File::Basename;
    chdir dirname(__FILE__);
};

use strict;
use warnings;
use threads ('stack_size' => 131072);
use threads::shared;
use Net::Ping;
use POSIX qw(strftime);
use Time::HiRes qw(usleep);
use Net::SNMP;
use Data::Dumper;
use JSON;
require HttpAPI;

binmode(STDOUT,':utf8');
#print threads->get_stack_size();
#exit;


use constant API_TOKEN		=> 'seckey';
use constant API_URL		=> 'http://127.0.0.1:88/device_monitor_API.php';
use constant PID_FILE		=> '/var/run/ping_snmp_netmon.pid';
use constant MAX_SNMP_THREADS	=> 2;
use constant MAX_PING_THREADS	=> 32;

# Global scope visibility for sub's
my $RUNNING = 1;
share($RUNNING);

# Catch signals
#$SIG{INT} = \&norm_exit;
#$SIG{HUP} = 'IGNORE';
# Catch terminate signals
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = \&stop_running;
$SIG{PIPE} = 'IGNORE';


# -------- Only check and read PID file
my $pid = 0;
if ( -e PID_FILE ) {
	print "WARN: PID file exists.\n";
	open(PIDF, PID_FILE) || die "ERROR: PID file '". PID_FILE ."' read error: $!"; # opening for read only
	$pid = <PIDF>;
	close(PIDF);
}

if ( $pid && -e "/proc/$pid/stat" ) { # Is proccess number already running by OS KERNEL
	die "ERROR: My process already exists (PID $pid). Exiting.\n";
}
# ---


my $now_time = localtime();
print "$now_time\n";


sub stop_running() {
	print "EXIT signal catched. RUNNING=0\n";
	$RUNNING = 0;
}

sub norm_exit($) {
	my $exit_code = $_[0];
	print "Deleting PID file '". PID_FILE ."'... \n";
	unlink(PID_FILE) || die "ERROR: PID file '". PID_FILE ."' delete error: $!";
	print "Done. Exiting.\n\n";
	exit($exit_code);
}

# -------- Create PID file
open(PIDNF, ">".PID_FILE) || die "ERROR: PID file '".PID_FILE."' write error: $!";
print(PIDNF "$$"); # write in to file current PID
close(PIDNF);
# ---


#my (%ping_dev_hosts_arr, %ping_dev_state_arr, %ping_dev_prev_state_arr);
#share (%ping_dev_state_arr);


my $http_api = HttpAPI->new(API_URL, API_TOKEN);
my %http_api_reply = ();



#------------------- device' SNMP monitor -----------------------------------------
print "------------------- device' SNMP monitor -----------------------------------------\n";

print "Requesting SNMP jobs from HTTP API Server ...\n";
%http_api_reply = %{$http_api->query( ['cmd' => 'get_snmp_devices_list'] )};
#print Dumper \%http_api_reply;

#norm_exit;


if ( $http_api_reply{'error_status'} != 0 ) {
	$RUNNING=0;
	print "Some bad happens on API HTTP Query-Response!\n";
	print Dumper \%http_api_reply;
	norm_exit(254);
}

my %snmp_devices_shared :shared;

my %snmp_results_shared :shared;

my (@snmp_threads_list);

while ( my($monitor_id, $data) = each %{$http_api_reply{'snmp_devices_list'}} ){
	#print $monitor_id ."\n";
	#print $data->{'mon_name'} ."\n";

	# Объявляем вложение SHARED
	$snmp_devices_shared{$monitor_id} = &share({});

	$snmp_devices_shared{$monitor_id}->{'dev_name'} = $data->{'dev_name'};
	$snmp_devices_shared{$monitor_id}->{'mon_name'} = $data->{'mon_name'};

	$snmp_devices_shared{$monitor_id}->{'dev_ip'} = $data->{'dev_ip'};
	$snmp_devices_shared{$monitor_id}->{'snmp_community'} = $data->{'snmp_community'};
	$snmp_devices_shared{$monitor_id}->{'snmp_oid'} = $data->{'snmp_oid'};
	$snmp_devices_shared{$monitor_id}->{'double_query'} = $data->{'double_query'};
	$snmp_devices_shared{$monitor_id}->{'query_result'} = '';
	$snmp_devices_shared{$monitor_id}->{'query_error_state'} = '';
	$snmp_devices_shared{$monitor_id}->{'snmp_error_info'} = '';
}

print "SNMP Jobs COUNT is: ". (scalar keys %snmp_devices_shared) ."\n";

for ( my $tcount=1; $tcount <= (scalar keys %snmp_devices_shared) && $tcount <= MAX_SNMP_THREADS ; $tcount++ ) {
	print "Starting SNMP thread #". $tcount ."\n";
	push(@snmp_threads_list, threads->create("startsnmp") );
}

foreach (@snmp_threads_list) {
	$_->join();
}

#print Dumper \%snmp_results_shared;


if ( (scalar keys %snmp_results_shared) > 0 && $RUNNING==1 ) {
	print "Sending SNMP results to HTTP API Server ...\n";
	%http_api_reply = %{$http_api->query( ['cmd' => 'save_snmp_monitor_result', 'results' => encode_json(\%snmp_results_shared)] )};

	print "HTTP API Server response is:\n";
	print Dumper \%http_api_reply;
}

undef @snmp_threads_list;
undef %snmp_devices_shared;
undef %snmp_results_shared;



sub startsnmp {
	#my ($mon_id) = @_;
	my %cp; #copy of snmp_devices_shared hash pop
	my $mon_id; # DB monitor row id

	my ($snmp, $error, $result, $snmp_result);

	my $first_res = 0;
	my $last_res = 0;
	my $diff_perc = 0;
	my $double_query_max_probes = 5;
	my $probes_count = 0;

	while (1) {
		if ( $RUNNING == 0 ) {
			print "Got RUNNING==0, thread exiting...\n";
			return;
		}

		{
			lock(%snmp_devices_shared);
			#sleep(2);
			#lock(%snmp_results_shared);

			# shift one key from hash
			unless ( $mon_id = (keys %snmp_devices_shared)[0] ) {
				# nothing to pop from hash
				print "... Nothing to do. Thread exiting.\n";
				return;
			}

			#print Dumper \$mon_id;

			# copy data from hash by selected key
			%cp = %snmp_devices_shared{$mon_id};
			#print Dumper \%cp;

			# delete row from source hash by selected key
			delete $snmp_devices_shared{$mon_id};
			#print Dumper \%snmp_devices_shared;

			$probes_count = 0;
		}

		print "[SNMP collector for monitor_id:$mon_id STARTED] ". $cp{$mon_id}->{'dev_ip'} ." : ". $cp{$mon_id}->{'snmp_oid'} ." - ". $cp{$mon_id}->{'dev_name'} ." : ". $cp{$mon_id}->{'mon_name'} ."\n";

		do {
			($snmp, $error) = Net::SNMP->session(-hostname  => $cp{$mon_id}->{'dev_ip'}, -community => $cp{$mon_id}->{'snmp_community'}, -version => '1', -timeout => '2', -retries => '3', -translate => 1);
			$result = '';
			$snmp_result = '';

			$snmp_results_shared{$mon_id} = &share({});
			$snmp_results_shared{$mon_id}{'query_result'} = '';
			$snmp_results_shared{$mon_id}{'query_error_state'} = 0;
			$snmp_results_shared{$mon_id}{'snmp_error_info'} = '';

			if (defined $snmp) {
				$result = $snmp->get_request(-varbindlist => [$cp{$mon_id}->{'snmp_oid'}]);
				if (defined $result) {
					if ( exists( $result->{$cp{$mon_id}->{'snmp_oid'}} ) ) {
						$snmp_results_shared{$mon_id}{'query_result'} = $result->{$cp{$mon_id}->{'snmp_oid'}};
					} else {
						# It's a crutch - fix it!
						$snmp_results_shared{$mon_id}{'query_result'} = 'invalidOid';
						$snmp_results_shared{$mon_id}->{'query_error_state'} = 1;
						$snmp_results_shared{$mon_id}->{'snmp_error_info'} = 'invalidOid';
					}
					#print Dumper \$result;
				} else {
					$snmp_results_shared{$mon_id}->{'query_error_state'} = 1;
					$snmp_results_shared{$mon_id}->{'snmp_error_info'} = $snmp->error();
					printf "ERROR query monitor_id:$mon_id: %s.\n", $snmp->error();
				}
				$snmp->close();
			} else {
				$snmp_results_shared{$mon_id}->{'query_error_state'} = 1;
				$snmp_results_shared{$mon_id}->{'snmp_error_info'} = $error;
				printf "ERROR query mon_id:$mon_id: %s.\n", $error;
			}

			next if $snmp_results_shared{$mon_id}->{'query_error_state'} == 1;

			if ( $cp{$mon_id}{'double_query'} == 1 ) {
				#print "!!!!! DOUBLE QUERY !!!!!\n";
				$last_res = $first_res;
				$first_res = $snmp_results_shared{$mon_id}{'query_result'};
				#$first_res = 0; #######

				$diff_perc = 100;
				eval {
					$diff_perc = abs( ( ($first_res-$last_res) / abs(($first_res+$last_res)*0.5) ) * 100 );
				};

				print "[monitor_id:$mon_id] DOUBLE QUERY - F: $first_res, L: $last_res = DIFF_PERC: $diff_perc %\n";
				sleep 1;
			}

			$probes_count++;
			#print "probes_count: $probes_count\n";

		} while ( ($diff_perc > 5) && ($probes_count < $double_query_max_probes) );

		print "[SNMP collector for monitor_id:$mon_id ENDED] Result: ". $snmp_results_shared{$mon_id}->{'query_result'} ."\n";
		#sleep 1;
	}
}


norm_exit(254) if $RUNNING==0;

print "\n\n\n\n\n";

#norm_exit(0);

#------------------- device' PING monitor -----------------------------------------
print "------------------- device' PING monitor -----------------------------------------\n";

print "Requesting PING jobs from HTTP API Server ...\n";
%http_api_reply = %{$http_api->query( ['cmd' => 'get_ping_devices_list'] )};
#print Dumper \%http_api_reply;

if ( $http_api_reply{'error_status'} != 0 ) {
	$RUNNING=0;
	print "Some shit happens on API HTTP Query->Response!\n";
	print Dumper \%http_api_reply;
	norm_exit(254);
}

my %ping_devices_shared :shared;

my %ping_results_shared :shared;

my (@ping_threads_list);


while ( my($monitor_id, $ip) = each %{$http_api_reply{'ping_devices_list'}} ){
	#print "$monitor_id - $ip \n";
	$ping_devices_shared{$monitor_id} = $ip;
}

print "PING Jobs COUNT: ". (scalar keys %ping_devices_shared) ."\n\n";

for ( my $tcount=1; $tcount <= (scalar keys %ping_devices_shared) && $tcount <= MAX_PING_THREADS; $tcount++ ) {
	print "Starting PING thread #". $tcount ."\n";
	push(@ping_threads_list, threads->create("startPing") );
}

foreach (@ping_threads_list) {
	$_->join();
}

#print Dumper \%ping_results_shared;


sub startPing {
	my %cp; #copy of ping_devices_shared hash pop
	my $mon_id; # DB monitor row id

	while (1) {
		if ( $RUNNING == 0 ) {
			print "Got RUNNING==0, thread is exiting...\n";
			return;
		}

		{
			lock(%ping_devices_shared);

			# shift one key from hash
			unless ( $mon_id = (keys %ping_devices_shared)[0] ) {
				# nothing to pop from hash
				print "... Nothing to do. Thread is exiting.\n";
				return;
			}

			#print Dumper \$mon_id;

			# copy data from hash by selected key
			%cp = %ping_devices_shared{$mon_id};
			#print Dumper \%cp;

			# delete row from source hash by selected key
			delete $ping_devices_shared{$mon_id};
			#print Dumper \%snmp_devices_shared;
		}

		print "[PING probe for monitor_id:$mon_id STARTED] ". $cp{$mon_id} ."\n";

		$ping_results_shared{$mon_id} = 0;


		my $ping_probes = 4; # ping probes
		my $good_replies = 3; # good replies for state ALIVE

		my $p = Net::Ping->new("icmp",1,32);
		my $ping_stats = 0;

		for (my $i=1; $i<=$ping_probes; $i++) {
			if ( $p->ping($cp{$mon_id}) ) {
				$ping_stats++;
				# Sleep for 0.5 second
				#usleep(500000);
				select(undef, undef, undef, 0.5);
			}
		}

		$p->close();
		#print "probes: $ping_probes good: $ping_stats - ";

		if ( $ping_stats >= $good_replies ) {
			$ping_results_shared{$mon_id} = 1;
			print "[PING probe for monitor_id:$mon_id ENDED] probes $ping_probes good $ping_stats for ". $cp{$mon_id} ." is +ALIVE\n";
		} else {
			$ping_results_shared{$mon_id} = 0;
			print "[PING probe for monitor_id:$mon_id ENDED] probes $ping_probes good $ping_stats for ". $cp{$mon_id} ." is -down\n";
		}
	}
}

print "\n\n\n";

if ( (scalar keys %ping_results_shared) > 0 && $RUNNING==1 ) {
	print "Sending PING results to HTTP API Server ...\n";
	%http_api_reply = %{$http_api->query( ['cmd' => 'save_ping_monitor_result', 'results' => encode_json(\%ping_results_shared)] )};

	print "HTTP API Server response is:\n";
	print Dumper \%http_api_reply;
}


undef @ping_threads_list;
undef %ping_devices_shared;
undef %ping_results_shared;



print "ALL THE JOBS FINISHED!!!\n\n";

#sleep(10);

if ( $RUNNING ) {
	norm_exit(0);
} else {
	norm_exit(254); # error exit
}



