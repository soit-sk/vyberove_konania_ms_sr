#!/usr/bin/perl

use strict;
use warnings;

use lib '/home/lkundrak/src/perl-database-dumptruck/lib';

use URI;
use WWW::Mechanize;
use HTML::TreeBuilder 5 -weak;
use Database::DumpTruck;

my $root = new URI ('http://www.justice.gov.sk/Stranky/Ministerstvo/Vyberove-konania-v-rezorte/Zoznam-vyberovych-konani.aspx');
my $mech = new WWW::Mechanize;
my $dt = new Database::DumpTruck ({ dbname => 'data.sqlite', table => 'swdata' });

sub do_detail
{
	my $resp = shift;

	my $tree = new_from_content HTML::TreeBuilder ($resp->decoded_content);

	# This is what we deal with:
	#
	# <div  class="DetailTable">
	#     <div class="popiska">Organizácia:</div>
	#     <div class="hodnota">Okresný súd Košice I</div>
	#     <div class="riadok"></div>
	# 
	#     <div class="popiska">Pozícia:</div>
	#     <div class="hodnota">absolvenská prax</div>
	#     <div class="riadok"></div>
	# ...
	#     <div class="skupina">Prehľad prihlásených uchádzačov:</div>
	#     <div class="riadok ciara"></div>
	# 
	#     <div>
	# 
	# </div>
	# </div>

	my ($table) = $tree->look_down (class => 'DetailTable');
	my @divs = $table->look_down (_tag => 'div', sub {
		($_[0]->attr('class') || '') eq 'popiska'
		or ($_[0]->attr('class') || '') eq 'hodnota'});

	my %row;
	while (@divs >= 2) {
		my $popiska = shift @divs;
		my $hodnota = shift @divs;

		my ($k, $v) = ($popiska->as_trimmed_text,
			$hodnota->as_trimmed_text);

		# Beautify a bit!
		$k =~ s/:$//;

		# Is the value a link? Absolutize it!
		my ($link) = @{$hodnota->extract_links ('a')};
		$v = new URI ($link->[0])->abs ($resp->request->uri)->as_string
			if $link;

		$row{$k} = $v;
	}

	print $row{"D\x{e1}tum uz\x{e1}vierky"} . "\n";

	$dt->upsert (\%row);
}

# Roll!
$mech->get ($root);
do {
	
	do_detail ($mech->clone->get ($_)) foreach
		$mech->find_all_links (url_regex => qr/Detail-vyberoveho-konania.aspx/);

	# The pager element. Retarded.
	my ($pager) = $mech->find_all_inputs (name_regex => qw/cmbAGVPager$/);
	$pager->value ($pager->value + 1);

	# Page still valid?
	if (grep { $_ == $pager->value } $pager->possible_values) {
		$mech->submit_form;
	} else {
		# Destroy the agent, we're done.
		$mech = undef;
	}
} while ($mech);

$dt->create_index(['Vyhlásenie konania'], undef, 'IF NOT EXISTS', 'UNIQUE');
