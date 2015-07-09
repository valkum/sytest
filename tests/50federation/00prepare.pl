use File::Basename qw( dirname );
use JSON qw( decode_json );

use IO::Socket::IP 0.04; # ->sockhostname

use Crypt::NaCl::Sodium;

my $DIR = dirname( __FILE__ );

struct FederationParams => [qw( server_name key_id public_key secret_key )];

prepare "Creating inbound federation HTTP server",
   provides => [qw( local_server_name inbound_server )],

   do => sub {
      my $inbound_server = SyTest::Federation::Server->new;
      $loop->add( $inbound_server );

      provide inbound_server => $inbound_server;

      require IO::Async::SSL;

      $inbound_server->listen(
         host    => "localhost",
         service => "",
         extensions => [qw( SSL )],

         SSL_key_file => "$DIR/server.key",
         SSL_cert_file => "$DIR/server.crt",
      )->on_done( sub {
         my ( $listener ) = @_;
         my $sock = $listener->read_handle;

         my $server_name = sprintf "%s:%d", $sock->sockhostname, $sock->sockport;

         provide local_server_name => $server_name;

         my ( $pkey, $skey ) = Crypt::NaCl::Sodium->sign->keypair;

         my $fedparams = FederationParams( $server_name, "ed25519:1", $pkey, $skey );

         $listener->configure(
            federation_params => $fedparams,
         );
      });
   };

# A small test to check that our own federation server simulation is working
# correctly. If this test fails, it *ALWAYS* indicates a failure of SyTest
# itself and not of the homeserver being tested.
test "Checking local federation server",
   requires => [qw( local_server_name inbound_server http_client )],

   check => sub {
      my ( $local_server_name, $inbound_server, $client ) = @_;

      my $key_id = $inbound_server->key_id;

      $client->do_request(
         method => "GET",
         uri    => "https://$local_server_name/_matrix/key/v2/server/$key_id",
      )->then( sub {
         my ( $body ) = @_;
         log_if_fail "Keyserver response", $body;

         require_json_keys( $body, qw( server_name valid_until_ts verify_keys signatures tls_fingerprints ));

         require_json_string( $body->{server_name} );
         $body->{server_name} eq $local_server_name or
            die "Expected server_name to be $local_server_name";

         require_json_number( $body->{valid_until_ts} );
         $body->{valid_until_ts} / 1000 > time or
            die "Key valid_until_ts is in the past";

         keys %{ $body->{verify_keys} } or
            die "Expected some verify_keys";

         exists $body->{verify_keys}{$key_id} or
            die "Expected to find the '$key_id' key in verify_keys";

         require_json_keys( my $key = $body->{verify_keys}{$key_id}, qw( key ));

         require_base64_unpadded( $key->{key} );

         keys %{ $body->{signatures} } or
            die "Expected some signatures";

         $body->{signatures}{$local_server_name} or
            die "Expected a signature from $local_server_name";

         my $signature = $body->{signatures}{$local_server_name}{$key_id} or
            die "Expected a signature from $local_server_name using $key_id";

         require_base64_unpadded( $signature );

         # TODO: verify it?

         require_json_list( $body->{tls_fingerprints} );
         @{ $body->{tls_fingerprints} } > 0 or
            die "Expected some tls_fingerprints";

         foreach ( @{ $body->{tls_fingerprints} } ) {
            require_json_object( $_ );

            # TODO: Check it has keys named by the algorithms
         }

         Future->done(1);
      });
   };

package SyTest::Federation::Server;
use base qw( Net::Async::HTTP::Server );

use Protocol::Matrix qw( sign_json encode_base64_unpadded );

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( federation_params )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   $self->SUPER::configure( %params );
}

sub key_id
{
   my $self = shift;
   return $self->{federation_params}->key_id;
}

sub make_request
{
   my $self = shift;
   # This is to be found in tests/01http-server.pl
   return SyTest::HTTPServer::Request->new( @_ );
}

sub on_request
{
   my $self = shift;
   my ( $req ) = @_;

   my $path = $req->path;
   unless( $path =~ s{^/_matrix/}{} ) {
      $req->respond( HTTP::Response->new( 404, "Not Found", [ Content_Length => 0 ] ) );
      return;
   }

   my @pc = split m{/}, $path;
   my @trial;
   while( @pc ) {
      push @trial, shift @pc;
      if( my $code = $self->can( "on_request_" . join "_", @trial ) ) {
         $self->adopt_future(
            $code->( $self, $req, @pc )->on_done( sub {
               my ( $resp ) = @_;  # TODO: consider a type =>  ?

               my $fedparams = $self->{federation_params};

               sign_json( $resp,
                  secret_key => $fedparams->secret_key,
                  origin     => $fedparams->server_name,
                  key_id     => $fedparams->key_id,
               );

               $req->respond_json( $resp );
            })
         );
         return;
      }
   }

   print STDERR "TODO: Respond to request to /_matrix/${\join '/', @trial}\n";

   $req->respond( HTTP::Response->new( 404, "Not Found", [ Content_Length => 0 ] ) );
}

sub on_request_key_v2_server
{
   my $self = shift;
   my ( $req, $keyid ) = @_;

   my $sock = $req->stream->read_handle;
   my $ssl = $sock->_get_ssl_object;  # gut-wrench into IO::Socket::SSL - see RT105733
   my $cert = Net::SSLeay::get_certificate( $ssl );

   my $algo = "sha256";
   my $fingerprint = Net::SSLeay::X509_digest( $cert, Net::SSLeay::EVP_get_digestbyname( $algo ) );

   my $fedparams = $self->{federation_params};

   Future->done( {
      server_name => $fedparams->server_name,
      tls_fingerprints => [
         { $algo => encode_base64_unpadded( $fingerprint ) },
      ],
      valid_until_ts => ( time + 86400 ) * 1000, # +24h in msec
      verify_keys => {
         $fedparams->key_id => {
            key => encode_base64_unpadded( $fedparams->public_key ),
         },
      },
      old_verify_keys => {},
   } );
}
