# Copyright 2019 The Matrix.org Foundation C.I.C
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

my $creator_fixture = local_user_fixture();

test "An event which redacts an event in a different room should be ignored",
   requires => [
      $main::OUTBOUND_CLIENT,
      $main::INBOUND_SERVER,
      $main::HOMESERVER_INFO[0],
      $creator_fixture,
      room_fixture( $creator_fixture, room_version => "1" ),
      room_fixture( $creator_fixture, room_version => "1" ),
      federation_user_id_fixture(),
   ],

   do => sub {
      my ( $outbound_client, $inbound_server, $info, $creator, $room_id_1, $room_id_2, $user_id ) = @_;
      my $first_home_server = $info->server_name;

      my ( $room_1, $room_2 );
      my ( $msg_event_id, $redaction_event_id );

      # join both rooms
      $outbound_client->join_room(
         server_name => $first_home_server,
         room_id     => $room_id_1,
         user_id     => $user_id,
      )->then( sub {
         ( $room_1 ) = @_;

         $outbound_client->join_room(
            server_name => $first_home_server,
            room_id     => $room_id_2,
            user_id     => $user_id,
         );
      })->then( sub {
         ( $room_2 ) = @_;

         # send an event in one room
         my $event = $room_1->create_and_insert_event(
            type => "m.room.message",
            sender  => $user_id,
            content => {
               body => "hi",
            },
         );

         $msg_event_id = $event->{event_id};

         Future->needs_all(
            $outbound_client->send_event(
               event => $event,
               destination => $first_home_server,
            ),
            await_sync_timeline_contains(
               $creator, $room_id_1, check => sub {
                  $_[0]->{event_id} eq $msg_event_id
               }
            ),
         ),
      })->then( sub {
         # now send an event in another room which claims to redact it
         my $event = $room_2->create_and_insert_event(
            type     => "m.room.redaction",
            sender   => $user_id,
            content  => {},
            redacts  => $msg_event_id,
         );

         $redaction_event_id = $event->{event_id};

         log_if_fail "Sending redaction", $event;

         $outbound_client->send_event(
            event => $event,
            destination => $first_home_server,
         );
      })->then( sub {
         # send another regular event as a sentinel, and make sure the redaction doesn't
         # turn up.

         my $event = $room_2->create_and_insert_event(
            type => "m.room.message",
            sender  => $user_id,
            content => {
               body => "sentinel",
            },
         );

         my $event_id = $event->{event_id};

         Future->needs_all(
            $outbound_client->send_event(
               event => $event,
               destination => $first_home_server,
            ),
            await_sync_timeline_contains(
               $creator, $room_id_2, check => sub {
                  my ( $ev ) = @_;
                  if ( $ev->{event_id} eq $redaction_event_id ) {
                     log_if_fail "Received redaction :/", $ev;
                     die "redaction was not rejected";
                  }
                  return $ev->{event_id} eq $event_id;
               }
            )
         );
      })->then( sub {
         # now fetch the original event again, and check it's not redacted
         matrix_get_event( $creator, $room_id_1, $msg_event_id );
      })->then( sub {
         my ( $fetched ) = @_;

         log_if_fail "Fetched original message event", $fetched;
         assert_json_keys( $fetched->{content}, qw( body ) );
         assert_eq( $fetched->{content}->{body}, "hi" );
         Future->done;
      });
   };



test "An event which redacts itself should be ignored",
   requires => [
      $main::OUTBOUND_CLIENT,
      $main::INBOUND_SERVER,
      $main::HOMESERVER_INFO[0],
      local_user_and_room_fixtures( room_opts => { room_version => "1" } ),
      federation_user_id_fixture(),
   ],

   do => sub {
      my ( $outbound_client, $inbound_server, $info, $creator, $room_id, $user_id ) = @_;
      my $first_home_server = $info->server_name;

      my ( $room );

      my $event_id = '$lolredact:' . $outbound_client->server_name;

      $outbound_client->join_room(
         server_name => $first_home_server,
         room_id     => $room_id,
         user_id     => $user_id,
      )->then( sub {
         ( $room ) = @_;

         # create an event which claims to redact itself.
         my $event = $room->create_and_insert_event(
            event_id => $event_id,
            type     => "m.room.redaction",
            sender   => $user_id,
            redacts  => $event_id,
            content  => {},
         );

         log_if_fail "Sending redaction inception", $event;

         $outbound_client->send_event(
            event => $event,
            destination => $first_home_server,
         );
      })->then( sub {
         await_sync_timeline_contains(
            $creator, $room_id, check => sub {
               $_[0]->{event_id} eq $event_id
            }
         )
      });
   };


test "A pair of events which redact each other should be ignored",
   requires => [
      $main::OUTBOUND_CLIENT,
      $main::INBOUND_SERVER,
      $main::HOMESERVER_INFO[0],
      local_user_and_room_fixtures( room_opts => { room_version => "1" } ),
      federation_user_id_fixture(),
   ],

   do => sub {
      my ( $outbound_client, $inbound_server, $info, $creator, $room_id, $user_id ) = @_;
      my $first_home_server = $info->server_name;

      my ( $room );

      my $redaction1 = $outbound_client->{datastore}->next_event_id( "redaction1" );
      my $redaction2 = $outbound_client->{datastore}->next_event_id( "redaction2" );

      $outbound_client->join_room(
         server_name => $first_home_server,
         room_id     => $room_id,
         user_id     => $user_id,
      )->then( sub {
         ( $room ) = @_;

         my $event1 = $room->create_and_insert_event(
            event_id => $redaction1,
            type     => "m.room.redaction",
            sender   => $user_id,
            redacts  => $redaction2,
            content  => {},
         );

         log_if_fail "Sending first redaction", $event1;

         $outbound_client->send_event(
            event => $event1,
            destination => $first_home_server,
         );
      })->then( sub {
         my $event2 = $room->create_and_insert_event(
            event_id => $redaction2,
            type     => "m.room.redaction",
            sender   => $user_id,
            redacts  => $redaction1,
            content  => {},
         );

         log_if_fail "Sending second redaction", $event2;

         $outbound_client->send_event(
            event => $event2,
            destination => $first_home_server,
         );
      })->then( sub {
         await_sync_timeline_contains(
            $creator, $room_id, check => sub {
               $_[0]->{event_id} eq $redaction2
            }
         )
      });
   };

