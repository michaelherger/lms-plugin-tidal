package Plugins::TIDAL::InfoMenu;

use strict;
use Tie::Cache::LRU;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::TIDAL::API::Async;
use Plugins::TIDAL::Plugin;

my $log = Slim::Utils::Log->addLogCategory({
	'category'    => 'plugin.tidal',
	'description' => 'PLUGIN_TIDAL_NAME',
});

my $prefs = preferences('plugin.tidal');

# see note on memorizing feeds for different dispatches
my %rootFeeds;
tie %rootFeeds, 'Tie::Cache::LRU', 64;

sub init {
	my $class = shift;

#  |requires Client
#  |  |is a Query
#  |  |  |has Tags
#  |  |  |  |Function to call
	Slim::Control::Request::addDispatch( [ 'tidal_info', 'items', '_index', '_quantity' ],	[ 1, 1, 1, \&menuInfoWeb ]	);
	Slim::Control::Request::addDispatch( [ 'tidal_info', 'jive', '_action' ],	[ 1, 1, 1, \&menuInfoJive ]	);
	Slim::Control::Request::addDispatch( [ 'tidal_browse', 'items' ],	[ 1, 1, 1, \&menuBrowse ]	);
	Slim::Control::Request::addDispatch( [ 'tidal_browse', 'playlist', '_method' ],	[ 1, 1, 1, \&menuBrowse ]	);
}

sub menuInfoWeb {
	my $request = shift;

	# be careful that type must be artistS|albumS|playlistS|trackS
	my $type = $request->getParam('type');
	my $id = $request->getParam('id');

	$request->addParam('_index', 0);
	$request->addParam('_quantity', 10);

	# we can't get the response live, we must be called back by cliQuery to
	# call it back ourselves
	Slim::Control::XMLBrowser::cliQuery('tidal_info', sub {
		my ($client, $cb, $args) = @_;

		my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);

		$api->getFavorites( sub {
			my $favorites = shift || [];
			my $action;

			if ($type =~ /playlist/) {
				$action = (grep { $_->{uuid} == $id } @$favorites) ? 'remove' : 'add';
			} else {
				$action = (grep { $_->{id} == $id && ($type =~ /$_->{type}/i || !$_->{type}) } @$favorites) ? 'remove' : 'add';
			}

			my $title = $action eq 'remove' ? cstring($client, 'PLUGIN_FAVORITES_REMOVE') : cstring($client, 'PLUGIN_FAVORITES_SAVE');
			$title .= ' (' . cstring($client, 'PLUGIN_TIDAL_ON_TIDAL') . ')';

			my $items = [];
			
			my $item = { 
				type => 'link',
				name => $title,
			};

			if ($request->getParam('menu')) {
				push @$items, { %$item, 
					isContextMenu => 1,
					refresh => 1,
					jive => {
						nextWindow => 'parent',
						actions => {
							go => {
								player => 0,
								cmd    => [ 'tidal_info', 'jive', $action ],
								params => {	type => $type, id => $id }
							}
						},
					},
				};
			} else {
				push @$items, ( { %$item,
					url => sub {
						my ($client, $ucb) = @_;
						$api->updateFavorite( sub {
							_completed($client, $ucb);
						}, $action, $type, $id );
					},
				}, { 
					type => 'link',
					name => cstring($client, 'ADD_THIS_SONG_TO_PLAYLIST') . ' (' . cstring($client, 'PLUGIN_TIDAL_ON_TIDAL') . ')',
					url => \&addToPlaylist,
					passthrough => [ { id => $id } ],
				} );
			}

			my $method;

			if ( $type =~ /tracks/ ) {
				$method = \&_menuTrackInfo;
			} elsif ( $type =~ /albums/ ) {
				$method = \&_menuAlbumInfo;
			} elsif ( $type =~ /artists/ ) {
				$method = \&_menuArtistInfo;
			} elsif ( $type =~ /playlists/ ) {
				$method = \&_menuPlaylistInfo;
=comment
			} elsif ( $type =~ /podcasts/ ) {
				$method = \&_menuPodcastInfo;
			} elsif ( $type =~ /episodes/ ) {
				$method = \&_menuEpisodeInfo;
=cut
			}

			$method->( $api, $items, sub {
				my ($icon, $entry) = @_;

				# we need to add favorites for cliQuery to add them
				$entry = Plugins::TIDAL::Plugin::_renderItem($client, $entry, { addArtistToTitle => 1 });
				my $favorites = Slim::Control::XMLBrowser::_favoritesParams($entry) || {};
				$favorites->{favorites_icon} = $favorites->{icon} if $favorites;
				$cb->( {
					type  => 'opml',
					%$favorites,
					image => $icon,
					items => $items,
					# do we need this one?
					name => $entry->{name} || $entry->{title},
				} );
			}, $args->{params});

		}, $type );

	}, $request );
}

sub addToPlaylist {
	my ($client, $cb, $args, $params) = @_;
	
	my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);

	$api->getFavorites( sub {
		my $items = [];
		
		# only present playlist that we have the right to modify
		foreach my $item ( @{$_[0] || {}} ) {
			next if $item->{creator}->{id} ne $api->userId;
		
			push @$items, {
				name => $item->{title},
				url => sub {
					my ($client, $cb, $args, $params) = @_;
					$api->updatePlaylist( sub {
						_completed($client, $cb);
					}, 'add', $params->{uuid}, $params->{trackId} );
				},	
				image => Plugins::TIDAL::API->getImageUrl($item, 'usePlaceholder'),
				passthrough => [ { trackId => $params->{id}, uuid => $item->{uuid} } ],
			};
		}

		$cb->( { items => $items } );
	}, 'playlists' );
}

sub menuInfoJive {
	my $request = shift;

	my $id = $request->getParam('id');
	my $api = Plugins::TIDAL::Plugin::getAPIHandler($request->client);
	my $action = $request->getParam('_action');
	
	if ($action =~ /removeTrack/ ) {
		my $playlistId = $request->getParam('playlistId');
		$api->updatePlaylist( sub { }, 'del', $playlistId, $id );
	} else {
		my $type = $request->getParam('type');
		$api->updateFavorite( sub { }, $action, $type, $id );
	}
}
	
sub menuBrowse {
	my $request = shift;

	my $client = $request->client;

	my $itemId = $request->getParam('item_id');
	my $type = $request->getParam('type');
	my $id = $request->getParam('id');

	$request->addParam('_index', 0);
	# TODO: why do we need to set that
	$request->addParam('_quantity', 200);

	main::INFOLOG && $log->is_info && $log->info("Browsing for item_id:$itemId or type:$type:$id");

	# if we are descending, no need to search, just get our root
	if ( defined $itemId ) {
		my ($key) = $itemId =~ /([^\.]+)/;
		my $cached = ${$rootFeeds{$key}};
		Slim::Control::XMLBrowser::cliQuery('tidal_browse', $cached, $request);
		return;
	}

	# this key will prefix each action's hierarchy that JSON will sent us which
	# allows us to find our back our root feed. During drill-down, that prefix
	# is removed and XMLBrowser descends the feed.
	# ideally, we would like to not have to do that but that means we leave some
	# breadcrums *before* we arrive here, in the _renderXXX familiy but I don't
	# know how so we have to build our own "fake" dispatch just for that
	# we only need to do that when we have to redescend further that hierarchy,
	# not when it's one shot
	my $key = $client->id =~ s/://gr;
	$request->addParam('item_id', $key);

	Slim::Control::XMLBrowser::cliQuery('tidal_browse', sub {
		my ($client, $cb, $args) = @_;

		if ( $type =~ /album/ ) {

			Plugins::TIDAL::Plugin::getAlbum($client, sub {
				my $feed = $_[0];
				$rootFeeds{$key} = \$feed;
				$cb->($feed);
			}, $args, { id => $id } );

		} elsif ( $type =~ /artist/ ) {

			Plugins::TIDAL::Plugin::getAPIHandler($client)->getArtist(sub {
				my $feed = Plugins::TIDAL::Plugin::_renderItem( $client, $_[0] ) if $_[0];
				$rootFeeds{$key} = \$feed;
				# no need to add any action, the root 'tidal_browse' is memorized and cliQuery
				# will provide us with item_id hierarchy. All we need is to know where our root
				# by prefixing item_id with a min 8-digits length hexa string
				$cb->($feed);
			}, $id );

		} elsif ( $type =~ /playlist/ ) {

			Plugins::TIDAL::Plugin::getAPIHandler($client)->playlist(sub {
				my $feed = Plugins::TIDAL::Plugin::_renderItem( $client, $_[0] ) if $_[0];
				# we don't need to memorize the feed as we won't redescend into it
				$cb->($feed);
			}, $id );

		} elsif ( $type =~ /track/ ) {

			# track must be in cache, no memorizing
			my $cache = Slim::Utils::Cache->new;
			my $track = Plugins::TIDAL::Plugin::_renderItem( $client, $cache->get('tidal_meta_' . $id), { addArtistToTitle => 1 } );
			$cb->([$track]);
=comment
		} elsif ( $type =~ /podcast/ ) {

			# we need to re-acquire the podcast itself
			Plugins::TIDAL::Plugin::getAPIHandler($client)->podcast(sub {
				my $podcast = shift;
				getPodcastEpisodes($client, $cb, $args, {
					id => $id,
					podcast => $podcast,
				} );
			}, $id );

		} elsif ( $type =~ /episode/ ) {

			# episode must be in cache, no memorizing
			my $cache = Slim::Utils::Cache->new;
			my $episode = Plugins::TIDAL::Plugin::_renderItem( $client, $cache->get('tidal_episode_meta_' . $id) );
			$cb->([$episode]);
=cut
		}
	}, $request );
}

sub _menuBase {
	my ($client, $type, $id, $params) = @_;

	my $items = [];

	push @$items, (
		_menuAdd($client, $type, $id, 'add', 'ADD_TO_END', $params->{menu}),
		_menuAdd($client, $type, $id, 'insert', 'PLAY_NEXT', $params->{menu}),
		_menuPlay($client, $type, $id, $params->{menu}),
	) if $params->{useContextMenu} || $params->{feedMode};

	return $items;
}

sub _menuAdd {
	my ($client, $type, $id, $cmd, $title, $menuMode) = @_;

	my $actions = {
			items => {
				command     => [ 'tidal_browse', 'playlist', $cmd ],
				fixedParams => { type => $type, id => $id },
			},
		};

	$actions->{'play'} = $actions->{'items'};
	$actions->{'add'}  = $actions->{'items'};

	return {
		itemActions => $actions,
		nextWindow  => 'parent',
		type        => $menuMode ? 'text' : 'link',
		playcontrol => $cmd,
		name        => cstring($client, $title),
	};
}

sub _menuPlay {
	my ($client, $type, $id, $menuMode) = @_;

	my $actions = {
			items => {
				command     => [ 'tidal_browse', 'playlist', 'load' ],
				fixedParams => { type => $type, id => $id },
			},
		};

	$actions->{'play'} = $actions->{'items'};

	return {
		itemActions => $actions,
		nextWindow  => 'nowPlaying',
		type        => $menuMode ? 'text' : 'link',
		playcontrol => 'play',
		name        => cstring($client, 'PLAY'),
	};
}

sub _menuTrackInfo {
	my ($api, $items, $cb, $params) = @_;

	my $cache = Slim::Utils::Cache->new;
	my $id = $params->{id};

	# if we are here, the metadata of the track is cached
	my $track = $cache->get("tidal_meta_$id");
	$log->error("metadata not cached for $id") && return [] unless $track;

	# play/add/add_next options except for skins that don't want it
	my $base = _menuBase($api->client, 'track', $id, $params);
	push @$items, @$base if @$base;
	
	# if we have a playlist id, then we might remove that track from playlist
	if ($params->{playlistId} ) {
		my $item = {
			type => 'link',
			name => cstring($api->client, 'REMOVE_THIS_SONG_FROM_PLAYLIST') . ' (' . cstring($api->client, 'PLUGIN_TIDAL_ON_TIDAL') . ')',
		};
			
		if ($params->{menu}) {
			push @$items, { %$item, 
				isContextMenu => 1,
				refresh => 1,
				jive => {
					nextWindow => 'parent',
					actions => {
						go => {
							player => 0,
							cmd    => [ 'tidal_info', 'jive', 'removeTrack' ],
							params => { id => $params->{id}, playlistId => $params->{playlistId} },
						}
					},
				},
			}
		} else {
			push @$items, { %$item, 
				url => sub {
					my ($client, $cb, $args, $params) = @_;
					$api->updatePlaylist( sub {
						_completed($api->client, $cb);
					}, 'del', $params->{playlistId}, $params->{id} );
				},	
				passthrough => [ $params ],
			}
		}
	}
	
	push @$items, ( {
		type => 'link',
		name =>  $track->{album},
		label => 'ALBUM',
		itemActions => {
			items => {
				command     => ['tidal_browse', 'items'],
				fixedParams => { type => 'album', id => $track->{album_id} },
			},
		},
	}, {
		type => 'link',
		name =>  $track->{artist}->{name},
		label => 'ARTIST',
		itemActions => {
			items => {
				command     => ['tidal_browse', 'items'],
				fixedParams => { type => 'artist', id => $track->{artist}->{id} },
			},
		},
	}, {
		type => 'text',
		name => sprintf('%s:%02s', int($track->{duration} / 60), $track->{duration} % 60),
		label => 'LENGTH',
	}, {
		type  => 'text',
		name  => $track->{url},
		label => 'URL',
		parseURLs => 1
	} );

	$cb->($track->{cover}, $track);
}

sub _menuAlbumInfo {
	my ($api, $items, $cb, $params) = @_;

	my $id = $params->{id};

	$api->album( sub {
		my $album = shift;

		# play/add/add_next options except for skins that don't want it
		my $base = _menuBase($api->client, 'album', $id, $params);
		push @$items, @$base if @$base;

		push @$items, ( {
			type => 'playlist',
			name =>  $album->{artist}->{name},
			label => 'ARTIST',
			itemActions => {
				items => {
					command     => ['tidal_browse', 'items'],
					fixedParams => { type => 'artist', id => $album->{artist}->{id} },
				},
			},
		}, {
			type => 'text',
			name => $album->{numberOfTracks} || 0,
			label => 'TRACK_NUMBER',
		}, {
			type => 'text',
			name => substr($album->{releaseDate}, 0, 4),
			label => 'YEAR',
		}, {
			type => 'text',
			name => sprintf('%s:%02s', int($album->{duration} / 60), $album->{duration} % 60),
			label => 'LENGTH',
		}, {
			type  => 'text',
			name  => $album->{url},
			label => 'URL',
			parseURLs => 1
		} );

		my $icon = Plugins::TIDAL::API->getImageUrl($album, 'usePlaceholder');
		$cb->($icon, $album);

	}, $id );
}

sub _menuArtistInfo {
	my ($api, $items, $cb, $params) = @_;

	my $id = $params->{id};

	$api->getArtist( sub {
		my $artist = shift;

		push @$items, ( {
			type => 'link',
			name =>  $artist->{name},
			url => 'N/A',
			label => 'ARTIST',
			itemActions => {
				items => {
					command     => ['tidal_browse', 'items'],
					fixedParams => { type => 'artist', id => $artist->{id} },
				},
			},
		}, {
			type  => 'text',
			name  => $artist->{url},
			label => 'URL',
			parseURLs => 1
		} );

		my $icon = Plugins::TIDAL::API->getImageUrl($artist, 'usePlaceholder');
		$cb->($icon, $artist);

	}, $id );
}

sub _menuPlaylistInfo {
	my ($api, $items, $cb, $params) = @_;

	my $id = $params->{id};

	$api->playlistData( sub {
		my $playlist = shift;

		# play/add/add_next options except for skins that don't want it
		my $base = _menuBase($api->client, 'playlist', $id, $params);
		push @$items, @$base if @$base;

		push @$items, ( {
			type => 'text',
			name =>  $playlist->{title},
			label => 'ALBUM',
		}, {
			type => 'text',
			name => $playlist->{numberOfTracks} || 0,
			label => 'TRACK_NUMBER',
		}, {
			type => 'text',
			name => substr($playlist->{created}, 0, 4),
			label => 'YEAR',
		}, {
			type => 'text',
			name => sprintf('%02s:%02s:%02s', int($playlist->{duration} / 3600), int(($playlist->{duration} % 3600)/ 60), $playlist->{duration} % 60),
			label => 'LENGTH',
		}, {
			type  => 'text',
			name  => $playlist->{url},
			label => 'URL',
			parseURLs => 1
		} );

		my $icon = Plugins::TIDAL::API->getImageUrl($playlist, 'usePlaceholder');
		$cb->($icon, $playlist);

	}, $id );
}

=comment
sub _menuPodcastInfo {
	my ($api, $items, $cb, $params) = @_;

	my $id = $params->{id};

	$api->podcast( sub {
		my $podcast = shift;

		# play/add/add_next options except for skins that don't want it
		my $base = _menuBase($api->client, 'podcast', $id, $params);
		push @$items, @$base if @$base;

		push @$items, ( {
			# put that one as an "album" otherwise control icons won't appear
			type => 'text',
			name =>  $podcast->{title},
			label => 'ALBUM',
		}, {
			type  => 'text',
			name  => $podcast->{link},
			label => 'URL',
			parseURLs => 1
		}, {
			type => 'text',
			name => $podcast->{description},
			label => 'COMMENT',
			parseURLs => 1
		} );

		my $icon = Plugins::TIDAL::API->getImageUrl($podcast, 'usePlaceholder');
		$cb->($icon, $podcast);

	}, $id );
}

sub _menuEpisodeInfo {
	my ($api, $items, $cb, $params) = @_;

	my $cache = Slim::Utils::Cache->new;
	my $id = $params->{id};

	# unlike tracks, we miss some information when drilling down on podcast episodes
	$api->episode( sub {
		my $episode = shift;

		# play/add/add_next options except for skins that don't want it
		my $base = _menuBase($api->client, 'episode', $id, $params);
		push @$items, @$base if @$base;

		push @$items, ( {
			# put that one as an "album" otherwise control icons won't appear
			type => 'text',
			name =>  $episode->{podcast}->{title},
			label => 'ALBUM',
		}, {
			type => 'text',
			name =>  $episode->{title},
			label => 'TITLE',
		}, {
			type => 'text',
			name => sprintf('%02s:%02s:%02s', int($episode->{duration} / 3600), int(($episode->{duration} % 3600)/ 60), $episode->{duration} % 60),
			label => 'LENGTH',
		}, {
			type => 'text',
			label => 'MODTIME',
			name => $episode->{date},
		}, {
			type  => 'text',
			name  => $episode->{link},
			label => 'URL',
			parseURLs => 1
		}, {
			type => 'text',
			name => $episode->{comment},
			label => 'COMMENT',
			parseURLs => 1
		} );

		my $icon = Plugins::TIDAL::API->getImageUrl($episode, 'usePlaceholder');
		$cb->($icon, $episode);

	}, $id );
}
=cut

sub _completed {
	my ($client, $cb) = @_;
	$cb->({
		items => [{
			type => 'text',
			name => cstring($client, 'COMPLETE'),
		}],
	});
}	


1;