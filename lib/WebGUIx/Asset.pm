package WebGUIx::Asset;

use Carp qw( croak );
use Moose;
use URI;
use WebGUIx::Constant;
use WebGUIx::View::Asset;
use WebGUIx::Template::File;

extends 'WebGUIx::Model';

has 'assetId' => (
    traits  => [qw/ DB Form /],
    is      => 'ro',
    isa     => 'Str',
    db      => {
        primary_key     => 1,
        size            => 22,
    },
    form    => {
        field       => 'Readonly',
        tab         => 'metadata',
    },
);

has 'revisionDate' => (
    traits  => [qw/ DB Form /],
    is      => 'ro',
    isa     => 'Int',
    db      => {
        primary_key     => 1,
    },
    form    => {
        field       => 'Readonly',
        tab         => 'metadata',
    },
);



#----------------------------------------------------------------------------

=head2 can_add ( session, ?user|userId )

Returns true if the user is allowed to add this asset to the current asset. 
The user is allowed to add this asset if they are in the C<addGroup> of the
asset class in this site's configuration file. The user must also pass a 
L<can_edit> check for the current asset. 

The user defaults to the current user if none is provided.

=cut

sub can_add { 
    my ( $class, $session, $user ) = @_;
    
    if ( !$user ) {
        # Default to current user
        $user       = $session->user;
    }
    elsif ( !ref $user ) {  
        # Must be a userId
        $user       = WebGUI::User->new( $session, $user );
    }
    
    my $group_id = $session->config->get("assets/" . $class . "/addGroup")
                || $WebGUIx::Constant::GROUPID_TURN_ADMIN_ON
                ;

    return $user->isInGroup( $group_id );
}

#----------------------------------------------------------------------------

=head2 can_edit ( ?user|userId )

Returns true if the user is allowed to edit this asset. Users can edit assets
if they are in the group specified by C<groupIdEdit> or if they are the owner
of the asset, specified by C<ownerUserId>.

The user defaults to the current user if none is provided.

=cut

sub can_edit { 
    my ( $self, $user ) = @_;
    my $session = $self->session;

    if ( !$user ) {
        # Default to current user
        $user       = $session->user;
    }
    elsif ( !ref $user ) {  
        # Must be a userId
        $user       = WebGUI::User->new( $session, $user );
    }
    
    return $user->isInGroup( $self->data->groupIdEdit );
}

#----------------------------------------------------------------------------

=head2 can_view ( ?user|userId )

Returns true if the user is allowed to view this asset. Users can view assets
if they are in the C<groupIdView> group or if they are the owner of the asset
specified by C<ownerUserId>.

=cut

sub can_view { 
    my ( $self, $user ) = @_;    
    my $session = $self->session;

    if ( !$user ) {
        # Default to the current user
        $user       = $session->user;
    }
    elsif ( !ref $user ) {
        $user       = WebGUI::User->new( $session, $user );
    }

    return $user->isInGroup( $self->data->groupIdView );
}

#----------------------------------------------------------------------------

=head2 cut ( )

Place the asset on the clipboard by changing state to "clipboard". 

All descendants get the state "clipboard-limbo" so they don't get interfered 
with while their ancestor is on the clipboard.

=cut

sub cut { 
    my ( $self ) = @_;
    
    $self->tree->state($WebGUIx::Constant::STATE_CLIPBOARD);
    for my $result ( $self->get_descendants ) {
        $result->state($WebGUIx::Constant::STATE_CLIPBOARD_LIMBO);
    }

    return;
}

#----------------------------------------------------------------------------

=head2 duplicate ( properties )

Create a complete copy of this asset. C<properties> is a hashref of properties
the new copy should have. See L<create()> for the structure of this hashref.

Used as the first step of a "copy" operation, followed by a "cut" of the new
duplicate.

NOTE: DBIx::Class::Row's copy() method will not propagate into all tables, 
because it needs to be used for versioning.

=cut

sub duplicate {
    my ( $self, $properties ) = @_;
    my $parent      = $self->get_parent;
    my $new_rank    = $self->get_next_sibling_rank;
    my $new_id      = $self->session->id->generate;
    my $new_lineage = sprintf '%s%06i', $parent->lineage, $new_rank;
    my $now     = time;
    $self->tree->copy( { assetId => $new_id, lineage => $new_lineage } );
    my $copy = $self->copy( { assetId => $new_id, revisionDate => $now } );
    
    return $copy;
}

#----------------------------------------------------------------------------

=head2 get_children ( constraints, options )

Get the children of this asset. C<constraints> is a hashref of constraints
for DBIx::Class. C<options> is a hashref of options for DBIx::Class.

Returns a DBIx::Class::ResultSet of WebGUIx::Asset::Tree objects.

You can use the L<WebGUI::Asset::Tree::as_asset> method to get the full
asset class if you need it.

=cut

sub get_children {
    my ( $self, $constraints, $options ) = @_;
    my $schema  = $self->result_source->schema;

    $constraints->{ parentId } = $self->assetId;

    return $schema->resultset('Tree')->search( $constraints, $options );
}

#----------------------------------------------------------------------------

=head2 get_container ( )

Get the container for this asset. The container is the ancestor that is the
entry point to this asset. It is used for two purposes:

 1) To bring the user in from a search
 2) To return the user after a delete, cut, promote, or demote

Example: An Article on a Layout, the container is the Layout.
Example: A Post in a Thread in a Forum, the container is the Forum.

Defaults to the asset's parent.

=cut

sub get_container {
    my ( $self ) = @_;
    return $self->get_parent;
}

#----------------------------------------------------------------------------

=head2 CLASS->get_current_revision_date ( session, assetId )

Get the most recent revision date the user is allowed to see. This is a class
method used to create asset instances when we don't know what revision date
to use.

=cut

sub get_current_revision_date {
    my ( $class, $session, $assetId ) = @_;
    my $schema = $session->{_schema};
    return $schema->resultset('Any')->search(
        {
            assetId     => $assetId,
        },
        {
            order_by    => { -desc => 'revisionDate' },
            rows        => 1,
        }
    )->single;
}

#----------------------------------------------------------------------------

=head2 get_descendants ( constraints, options )

Get the descendants of this asset. C<constraints> is a hashref of constraints
for DBIx::Class. C<options> is a hashref of options for DBIx::Class.

Returns a DBIx::Class::ResultSet of WebGUI::Asset::Tree objects.

You can use the L<WebGUI::Asset::Tree::as_asset> method to get the full
asset class if you need it.

=cut

sub get_descendants {
    my ( $self, $constraints, $options ) = @_;
    my $schema  = $self->result_source->schema;

    $constraints->{ lineage } = {
        LIKE => $self->tree->lineage . '%',
    };

    return $schema->resultset('Tree')->search( $constraints, $options );
}

#----------------------------------------------------------------------------

override get_edit_form => sub { 
    my ( $self ) = @_;
    my $form = super();
    $form->name( "edit_asset" );

    # XXX Add Data and Tree relationships
    my $data_form   = $self->data->get_edit_form;
    $form->combine( $data_form );

    return $form;
};

#----------------------------------------------------------------------------

=head2 get_last_modified ( )

Get the time this asset was last modified for browser cache purposes. Some
assets may want to return 0 to make sure their content is never cached.

Defaults to the C<revisionDate>

=cut

sub get_last_modified {
    my ( $self ) = @_;
    return $self->revisionDate;
}

#----------------------------------------------------------------------------

=head2 get_next_sibling_rank ( )

Get the next rank to create a new asset with

=cut

# XXX: Major hacks inside to work with old WebGUI assets
sub get_next_sibling_rank {
    my ( $self ) = @_;
    my $high_rank_child   # Not using get_children in case of old WebGUI assets
        = $self->session->{_schema}->resultset('Tree')->search( {
            parentId    => $self->tree->parentId,
        }, { 
            order_by    => {-desc => 'lineage'},
            rows        => 1,
        } )->single;
    $high_rank_child->lineage =~ /0*([1-9]\d{0,5})$/;
    my $rank    = $1 + 1; # Using lineage to determine rank in case of old WebGUI assets
    return $rank;
}

#----------------------------------------------------------------------------

=head2 get_parent ( )

Get the parent asset.

=cut

sub get_parent { 
    my ( $self ) = @_;
    return $self->result_source->schema->resultset('Tree')->find({
        assetId => $self->tree->parentId,
    });
    # XXX: Cannot return as_asset because parent might be old WebGUI asset
}

#----------------------------------------------------------------------------

=head2 get_url ( params )

Get an absolute URL to this asset. C<params> is an array of URL parameters
to add to the URL. Multiple values may be passed as an arrayref. See 
L<URI::query_form()> for info.

This is different from the C<url> property because it includes the site's 
gateway. 

If you want a full URL with schema and domain name, use get_url_full().

=cut

sub get_url {
    my ( $self, @params ) = @_;
    my $gateway = $self->session ? $self->session->url->gateway : "/";

    my $u   = URI->new_abs( $self->data->url, $gateway );
    if ( @params ) {
        $u->query_form( @params, ';' ); # seperate with ;
    }
    return $u->as_string;
}

#----------------------------------------------------------------------------

=head2 get_url_full ( params )

Get the full URL to this asset. C<params> is an array of URL parameters
to add to the URL. Multiple values may be passed as an arrayref. See 
L<URI::query_form()> for info.

This is different from the C<url> property because it includes the URL 
schema, domain name, and site gateway. 

This should only be used when creating URLs to send out via e-mail or RSS 
or etc...

=cut

sub get_url_full {
    my ( $self, @params ) = @_;
    
    my $u   = URI->new( $self->session->url->getSiteURL );
    $u->path( $self->session->url->gateway( $self->data->url ) );
    if ( @params ) {
        $u->query_form( @params, ';' ); # seperate with ;
    }
    return $u->as_string;
}

#----------------------------------------------------------------------------

=head2 has_children ( ) 

Returns true if the asset has any children

=cut

sub has_children {
    my ( $self ) = @_;
    my $rs
        = $self->result_source->schema->resultset('Tree')->find({
            parentId    => $self->assetId,
        });
    return 1 if $rs;
}

#----------------------------------------------------------------------------

=head2 log ( action, message )

Add an entry to the asset history log. C<action> is what the user is doing. 
C<message> is more details, such as which fields were edited, or why the
action is happening.

=cut

#sub log { ... }

#----------------------------------------------------------------------------

=head2 new ( )

Create or instanciate a new asset. If the asset cannot be instanciated, will
croak.

=cut

sub new {
    my ( $class, $attr ) = @_;
    my $session = $attr->{-result_source}->schema->session;

    # Autogenerate missing properties
    $attr->{ assetId                } ||= $session->id->generate;
    $attr->{ revisionDate           } ||= time;
    $attr->{ tree }{ assetId        } = $attr->{ assetId };
    $attr->{ tree }{ parentId       } ||= $WebGUIx::Constant::ASSETID_ROOT;
    $attr->{ tree }{ lineage        } ||= $attr->{ assetId }; # Will fix this below
    $attr->{ tree }{ className      } = $class;
    $attr->{ tree }{ state          } ||= "published";
    $attr->{ data }{ assetId        } = $attr->{ assetId };
    $attr->{ data }{ revisionDate   } = $attr->{ revisionDate };
    $attr->{ data }{ url            } ||= $attr->{ assetId };
    
    my $self = $class->next::method( $attr );

    # Generate a rank and lineage based on parent
    if ( $self->tree->lineage eq $self->assetId ) {
        $self->tree->rank( $self->get_next_sibling_rank );
        $self->tree->lineage( sprintf '%s%06i', $self->get_parent->lineage, $self->tree->rank );
    }

    return $self;
}

#----------------------------------------------------------------------------

=head2 prepare_view ( )

Prepare the template to be used in the L<view()> method. This allows us to do
as much as possible before the hard work of L<view()>. Also allows us to add
items to the <head> of the response. Returns a reference to a 
L<WebGUIx::Asset::Template> object.

=cut

sub prepare_view { 
    my ( $self ) = @_;    
    
    my $template_id = $self->template_id_view;

    # XXX
}

#----------------------------------------------------------------------------

=head2 paste ( asset ) 

=cut

sub paste {
    
}

#----------------------------------------------------------------------------

sub process_edit_form {
    my ( $self ) = @_;
    my $var = $self->get_edit_form->process;
    for my $attr ( $self->meta->get_all_attributes ) {
        next unless $attr->does('WebGUIx::Meta::Attribute::Trait::Form');
        next if $attr->form->{field} eq 'Readonly';
        my $name    = $attr->name;
        $self->$name( $var->{$name} );
    }

    for my $attr ( $self->data->meta->get_all_attributes ) {
        next unless $attr->does('WebGUIx::Meta::Attribute::Trait::Form');
        next if $attr->form->{field} eq 'Readonly';
        my $name    = $attr->name;
        $self->data->$name( $var->{$name} );
    }

    return;
}

#----------------------------------------------------------------------------
#sub publish { ... }
#----------------------------------------------------------------------------

=head2 session ( )

Get the WebGUI::Session object attached to this Asset.

=cut

#----------------------------------------------------------------------------

=head2 table ( table_name )

Set the table name for this asset. Must be called during loading after all 
attributes have been added:

 has 'attr' => (
    traits  => [qw{ DB }],
    is      => 'rw',
    isa     => 'Str',
 );

 __PACKAGE__->table("table_name")

=cut 

sub table {
    my ( $class, $table ) = @_;
    $class->SUPER::table( $table );
    $class->belongs_to(
        'data' => 'WebGUIx::Asset::Any',
        { 
            'foreign.assetId'         => 'self.assetId',
            'foreign.revisionDate'    => 'self.revisionDate',
        },
    );
    $class->belongs_to(
        'tree' => 'WebGUIx::Asset::Tree',
        { 
            'foreign.assetId' => 'self.assetId'
        },
    );
}

#----------------------------------------------------------------------------

=head2 view ( options )

Get the default view for this asset's content. Does not include the style
wrapper. Uses the template prepared by L<prepare_view()>. C<options> is a 
hashref of options that can be used by subclasses. Returns a 
L<WebGUIx::Asset::Template> with the default set of template variables.

Some default options:

    error       => An error message to show the user that something is wrong
    warning     => A warning to show the user that something may be wrong
    message     => An informational message to show the user

=cut

sub view { 
    my ( $self, $options ) = @_;
    my $template        = !$self->{_view_template}
                        ? $self->{_view_template}
                        : $self->prepare_view
                        ;
    

    return $template;
}

#----------------------------------------------------------------------------

sub www_add {
    my ( $self, %args ) = @_;
    my $session     = $self->session;

    my $new_class   = $session->form->get('className')
                    || $session->form->get('class') # old way, bad
                    ;
    my $new_asset   = $self->result_source->schema->resultset($new_class)->new({});
    my $form        = $new_asset->get_edit_form;
    $form->action( $self->get_url );
    $form->add_field( 'Hidden', name => 'func', value => 'add_save', );
    $form->add_field( 'Hidden', name => 'className', value => $new_class, );
    $form->add_field( 'Submit', name => 'save', label => 'Create', );
    my $tmpl        = WebGUIx::Template::File->new( file => 'asset/edit.html' );
    $tmpl->add_form( $form );
    $tmpl->var->{asset} = $self;
    return $tmpl;
}

#----------------------------------------------------------------------------

sub www_add_save {
    my ( $self, %args ) = @_;

    my $session     = $self->session;
    my $new_class   = $session->form->get('className');
    my $new_asset   = $self->result_source->schema->resultset($new_class)->new({});
    $new_asset->process_edit_form;
    $new_asset = $new_asset->insert;

    my $tmpl    = WebGUIx::Template::File->new( file => 'asset/edit_save.html' );
    $tmpl->var->{asset} = $new_asset;
    return $tmpl;
}

#----------------------------------------------------------------------------

sub www_edit { 
    my ( $self, %args ) = @_;
    my $tmpl    = WebGUIx::Template::File->new( file => 'asset/edit.html' );
    my $form    = $self->get_edit_form;
    $form->action( $self->get_url );
    $form->add_field( 'Hidden', name => 'func', value => 'edit_save', );
    $form->add_field( 'Submit', name => 'save', label => 'Save', );
    $tmpl->add_form($form);
    $tmpl->var->{asset} = $self;
    return $tmpl;
}

#----------------------------------------------------------------------------

sub www_edit_save { 
    my ( $self, ) = @_;
    
    $self->process_edit_form;
    $self->update;

    my $tmpl    = WebGUIx::Template::File->new( file => 'asset/edit_save.html' );
    $tmpl->var->{asset} = $self;
    return $tmpl;
}

#----------------------------------------------------------------------------

sub www_view {
    my ( $self ) = @_;
    return $self->view;
}

1;

