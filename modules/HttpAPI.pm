# Perl module HttpAPI.pm

package HttpAPI; {
	use strict;
	use LWP::UserAgent;
	use JSON;

	sub new() {
		my $name = shift;
		#print "Construct\n";
		my $self = {};

		$self->{'UA'} = undef;
		$self->{'API_URL'} = undef;
		$self->{'API_TOKEN'} = undef;
		$self->{'error_status'} = 0;


		if ( @_ ) { $self->{'API_URL'} = shift; } else {
			$self->{'error_status'} = 1;
			print "HttpAPI::new() Mising first argument API_URL\n";
		}

		if ( @_ ) { $self->{'API_TOKEN'} = shift; } else {
			$self->{'error_status'} = 1;
			print "HttpAPI::new() Mising second argument API_TOKEN\n";
		}

		#print "Params: ". $self->{'API_URL'} ." , ". $self->{'API_TOKEN'} ."\n";


		$self->{'UA'} = LWP::UserAgent->new();

		$self->{'UA'}->timeout(1);
		$self->{'UA'}->default_header('Accept-Encoding' => 'utf-8');
		$self->{'UA'}->default_header('Content-Type' => 'application/json');
		$self->{'UA'}->default_header('Pragma' => 'nocache');
		$self->{'UA'}->default_header('X-Auth-Token' => $self->{'API_TOKEN'} );

		bless ($self);
		return $self;
	}


	#my $response = $ua_handle->post(API_URL, ['test' => 'test1&3=45']);

	sub query() {
		my $self = shift;
		my $data_arr = undef;

		if ( @_ ) { $data_arr = shift; } else {
			print "HttpAPI::query() Missing an ARRAY of argument\n";
			return {'error_status' => 1};
		}

		if ( ref($data_arr) ne 'ARRAY') {
			print "HttpAPI::query() Argument isn`t ARRAY\n";
			return {'error_status' => 1};
		}

		if ( $self->{'error_status'} ) {
			print "HttpAPI::query() Unable to send HTTP query to server. Missing API_URL or API_TOKEN in constructor\n";
			return {'error_status' => 1};
		}


		#print "Data arr: ". $data_arr ."\n";
		#return 1;

		my $response = $self->{'UA'}->post($self->{'API_URL'}, $data_arr);

		if ($response->is_success) {
			#print "API_SERVER response: ". $response->decoded_content;
			#print "\n ------------------------ \n";

			eval {
				my $json_arr = decode_json($response->decoded_content);
				return $json_arr;
			} or do {
				print "HttpAPI: Parse JSON response from HTTP server failed!";
				return {'error_status' => 1};
			};
		} else {
			print "HttpAPI: ". $response->status_line ."\n";
			return {'error_status' => 1};
		}
	}
}

return 1;
