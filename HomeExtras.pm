package Plugins::TIDAL::HomeExtras;

use strict;

use Plugins::TIDAL::Plugin;

Plugins::TIDAL::HomeExtraHome->initPlugin();
Plugins::TIDAL::HomeExtraMix->initPlugin();
Plugins::TIDAL::HomeExtraMoods->initPlugin();

1;

package Plugins::TIDAL::HomeExtraBase;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	my $tag = $args{tag};

	$class->SUPER::initPlugin(
		feed => sub { handleFeed($tag, @_) },
		tag  => "TIDALExtras${tag}",
		extra => {
			title => $args{title},
			icon  => $args{icon} || Plugins::TIDAL::Plugin->_pluginDataFor('icon'),
			needsPlayer => 1,
		}
	);
}

sub handleFeed {
	my ($tag, $client, $cb, $args) = @_;

	$args->{params}->{menu} = "home_heroes_${tag}";

	Plugins::TIDAL::Plugin::handleFeed($client, $cb, $args);
}

sub handleExtra {
	my ($class, $client, $cb, $count) = @_;

	$class->SUPER::handleExtra($client, sub {
		my $results = shift;

		my $icon = Plugins::TIDAL::Plugin->_pluginDataFor('icon');
		foreach (@{$results->{item_loop} || []}) {
			$_->{icon} ||= $icon;
		}

		$cb->($results);
	}, $count);
}

1;


package Plugins::TIDAL::HomeExtraHome;

use base qw(Plugins::TIDAL::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_TIDAL_HERO_HOME',
		tag => 'home'
	);
}

1;


package Plugins::TIDAL::HomeExtraMix;

use base qw(Plugins::TIDAL::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_TIDAL_MY_HERO_MIX',
		tag => 'mix'
	);
}

1;


package Plugins::TIDAL::HomeExtraMoods;

use base qw(Plugins::TIDAL::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_TIDAL_MY_HERO_MIX',
		tag => 'moods'
	);
}

1;
