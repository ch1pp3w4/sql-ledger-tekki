#=====================================================================
# SQL-Ledger ERP
# Copyright (C) 2006
#
#  Author: DWS Systems Inc.
#     Web: http://www.sql-ledger.com
#
#=====================================================================
#
# user related functions
#
#=====================================================================

package User;


sub new {
  my ($type, $memfile, $login) = @_;
  my $self = {};

  if ($login ne "") {

    open(MEMBER, "$memfile");

    while (<MEMBER>) {
      if (/^\[\Q$login\E\]/) {
        while (<MEMBER>) {
          last if /^\[/;
          next if /^(#|\s)/;

          # remove comments
          s/^\s*#.*//g;

          # remove any trailing whitespace
          s/^\s*(.*?)\s*$/$1/;

          ($key, $value) = split /=/, $_, 2;

          $self->{$key} = $value;
        }

        $self->{login} = $login;
        $self->{lat} = "1";
        $self->{long} = "1";
        $self->{templates} ||= $self->{dbname};

        last;
      }
    }
    close MEMBER;
  }

  bless $self, $type;

}


sub country_codes {

  my %cc = ();
  my @language = ();

  # scan the locale directory and read in the LANGUAGE files
  opendir DIR, "locale";

  my @dir = grep /_utf/, readdir DIR;

  foreach my $dir (@dir) {
    next unless open(FH, "locale/$dir/LANGUAGE");
    @language = <FH>;
    close FH;

    $cc{$dir} = "@language";
  }

  closedir(DIR);

  %cc;

}


sub login {
  my ($self, $form, $userspath) = @_;

  my $rc = -1;

  if ($self->{login} ne "") {

    if ($self->{password} ne "") {
      return -2 unless $form->{password};
      chomp $self->{password};
      srand( time() ^ ($$ + ($$ << 15)) );

      my $password = crypt $form->{password}, substr($self->{login}, 0, 2);
      if ($self->{password} ne $password) {
        return -2;
      }
    }

    $self->{password} = $form->{password};

    return -1 unless $self->create_config("$userspath/$self->{login}.conf");

    $self->{dbpasswd} = unpack 'u', $self->{dbpasswd};

    # check if database is down
    my $dbh = DBI->connect($self->{dbconnect}, $self->{dbuser}, $self->{dbpasswd}) or $form->dberror;

    # we got a connection, check the version

    my %defaults;
    my $dbversion;
    my $dbversion2;
    my $audittrail;

    my $query = qq|SELECT * FROM defaults|;
    my $sth = $dbh->prepare($query);
    $sth->execute;

    if ($sth->{NAME}->[0] eq 'fldname') {
      %defaults = $form->get_defaults($dbh, \@{[qw(version version2 audittrail)]});
      $dbversion = $defaults{version};
      $dbversion2 = $defaults{version2} * 1;
      $audittrail = $defaults{audittrail};
    } else {
      $query = qq|SELECT version, audittrail FROM defaults|;
      ($dbversion, $audittrail) = $dbh->selectrow_array($query);
    }
    $sth->finish;

    my $login = $self->{login};
    $login =~ s/@.*//;

    # no error check for employee table, ignore if it does not exist
    $query = qq|SELECT id
                FROM employee
                WHERE login = '$login'|;
    ($id) = $dbh->selectrow_array($query);

    if ($audittrail) {
      $id *= 1;
      my $ref = "$ENV{REMOTE_ADDR}";
      $query = qq|INSERT INTO audittrail (trans_id, reference, action, employee_id)
                  VALUES ($id, '$ref', 'login', $id)|;
      $dbh->do($query);
    }

    # check if we are on Tekki 3.2.3
    if (!$dbversion2 && $dbversion eq '3.2.3') {
      $query = 'SELECT id FROM recent LIMIT 1';
      if ($dbh->selectrow_array($query)) {
        $dbversion = '3.2.2';
        $dbversion2 = 11;
        $query = q|UPDATE defaults SET fldvalue = ? WHERE fldname = 'version'|;
        $dbh->do($query, undef, $dbversion);
        $query = q|INSERT INTO defaults (fldname, fldvalue) VALUES ('version2', ?)|;
        $dbh->do($query, undef, $dbversion2);
      }
    }

    $dbh->disconnect;

    $rc = 0;

    if (($form->{dbversion} ne $dbversion || $form->{dbversion2} != $dbversion2) && $dbversion) {
      $rc = -4;
      $dbupdate = (calc_version($dbversion) < calc_version($form->{dbversion}));
      $dbupdate ||= $dbversion2 < $form->{dbversion2};
    }

    if ($dbupdate) {
      $rc = -5;

      # if DB2 bale out
      if ($myconfig{dbdriver} eq 'DB2') {
        $rc = -3;
      }
    }
  }

  $rc;

}


sub logout {
  my ($self, $myconfig, $form) = @_;

  my $dbh = $form->dbconnect($myconfig);
  my $query;

  my %defaults = $form->get_defaults($dbh, \@{['audittrail']});

  if ($defaults{audittrail}) {
    my $login = $form->{login};
    $login =~ s/\@.*//;
    $query = qq|SELECT id
                FROM employee
                WHERE login = '$login'|;
    my ($id) = $dbh->selectrow_array($query);
    $id *= 1;

    $query = qq|SELECT reference
                FROM audittrail
                WHERE employee_id = $id
                AND action = 'login'
                ORDER BY transdate DESC
                LIMIT 1|;
    my ($ref) = $dbh->selectrow_array($query);
    $ref ||= $ENV{REMOTE_ADDR};

    $query = qq|INSERT INTO audittrail (trans_id, reference, action, employee_id)
                VALUES ($id, '$ref', 'logout', $id)|;
    $dbh->do($query);
  }

  $form->remove_locks($myconfig, $dbh);

  $dbh->disconnect;

}


sub check_recurring {
  my ($self, $form) = @_;

  my $dbh = DBI->connect($self->{dbconnect}, $self->{dbuser}, $self->{dbpasswd}) or $form->dberror;

  my $query = qq|SELECT count(*) FROM recurring
                 WHERE enddate >= current_date AND nextdate <= current_date|;
  ($_) = $dbh->selectrow_array($query);

  $dbh->disconnect;

  $_;

}


sub dbconnect_vars {
  my ($form, $db) = @_;

  my %dboptions = (
     'Pg' => {
        'yy-mm-dd' => 'set DateStyle to \'ISO\'',
        'mm/dd/yy' => 'set DateStyle to \'SQL, US\'',
        'mm-dd-yy' => 'set DateStyle to \'POSTGRES, US\'',
        'dd/mm/yy' => 'set DateStyle to \'SQL, EUROPEAN\'',
        'dd-mm-yy' => 'set DateStyle to \'POSTGRES, EUROPEAN\'',
        'dd.mm.yy' => 'set DateStyle to \'GERMAN\''
             }
     );

  if ($form->{dbdriver} eq 'Oracle') {
    $dboptions{Oracle}{$form->{dateformat}} = qq|ALTER SESSION SET NLS_DATE_FORMAT = '$form->{dateformat}'|;
  }
  if ($form->{dbdriver} eq 'Sybase') {
    $dboptions{Sybase}{$form->{dateformat}} = qq|SET DateFormat $form->{dateformat}|;
  }

  $form->{dboptions} = $dboptions{$form->{dbdriver}}{$form->{dateformat}};

  if ($form->{encoding}) {
    $form->{dboptions} .= ';set client_encoding to \''.$form->{encoding}."'";
  }

  if ($form->{dbdriver} =~ /(Pg|Sybase)/) {
    $form->{dbconnect} = "dbi:$form->{dbdriver}:dbname=$db";
  }

  if ($form->{dbdriver} eq 'Oracle') {
    $form->{dbconnect} = "dbi:Oracle:sid=$form->{sid}";
  }

  if ($form->{dbhost}) {
    $form->{dbconnect} .= ";host=$form->{dbhost}";
  }
  if ($form->{dbport}) {
    $form->{dbconnect} .= ";port=$form->{dbport}";
  }

}


sub dbdrivers {

  my @drivers = DBI->available_drivers();

  return (grep { /(Sybase|Pg|Oracle)/ } @drivers);

}


sub dbsources {
  my ($self, $form) = @_;

  my @dbsources = ();
  my ($sth, $query);

  $form->{dbdefault} = $form->{dbuser} unless $form->{dbdefault};
  $form->{sid} = $form->{dbdefault};
  &dbconnect_vars($form, $form->{dbdefault});

  my $dbh = DBI->connect($form->{dbconnect}, $form->{dbuser}, $form->{dbpasswd}) or $form->dberror;


  if ($form->{dbdriver} eq 'Pg') {

    $query = qq|SELECT datname FROM pg_database|;
    $sth = $dbh->prepare($query);
    $sth->execute || $form->dberror($query);

    while (my ($db) = $sth->fetchrow_array) {

      if ($form->{only_acc_db}) {

        next if ($db =~ /^template/);

        &dbconnect_vars($form, $db);
        my $dbh = DBI->connect($form->{dbconnect}, $form->{dbuser}, $form->{dbpasswd}) or $form->dberror;

        $query = qq|SELECT tablename FROM pg_tables
                    WHERE tablename = 'defaults'
                    AND tableowner = '$form->{dbuser}'|;
        my $sth = $dbh->prepare($query);
        $sth->execute || $form->dberror($query);

        if ($sth->fetchrow_array) {
          push @dbsources, $db;
        }
        $sth->finish;
        $dbh->disconnect;
        next;
      }
      push @dbsources, $db;
    }
  }

  if ($form->{dbdriver} eq 'Oracle') {
    if ($form->{only_acc_db}) {
      $query = qq|SELECT owner FROM dba_objects
                  WHERE object_name = 'DEFAULTS'
                  AND object_type = 'TABLE'|;
    } else {
      $query = qq|SELECT username FROM dba_users|;
    }

    $sth = $dbh->prepare($query);
    $sth->execute || $form->dberror($query);

    while (my ($db) = $sth->fetchrow_array) {
      push @dbsources, $db;
    }
  }

  if ($form->{dbdriver} eq 'Sybase') {

    $query = qq|SELECT schemaname FROM syscat.schemata|;

    if ($form->{only_acc_db}) {
      $query = qq|SELECT tabschema FROM syscat.tables WHERE tabname = 'DEFAULTS'|;
    }

    $sth = $dbh->prepare($query);
    $sth->execute || $form->dberror($query);

    while (my ($db) = $sth->fetchrow_array) {
      push @dbsources, $db;
    }
  }

# JJR
  if ($form->{dbdriver} eq 'DB2') {
    if ($form->{only_acc_db}) {
      $query = qq|SELECT tabschema FROM syscat.tables WHERE tabname = 'DEFAULTS'|;
    } else {
      $query = qq|SELECT DISTINCT schemaname FROM syscat.schemata WHERE definer != 'SYSIBM' AND schemaname != 'NULLID'|;
    }

    $sth = $dbh->prepare($query);
    $sth->execute || $form->dberror($query);

    while (my ($db) = $sth->fetchrow_array) {
      push @dbsources, $db;
    }
  }
# End JJR

# the above is not used but leave it in for future reference
# DS, Oct. 28, 2003


  $sth->finish;
  $dbh->disconnect;

  return @dbsources;

}


sub dbcreate {
  my ($self, $form) = @_;

  for (qw(db encoding)) { $form->{$_} =~ s/;//g }

  my %dbcreate = ( 'Pg' => qq|CREATE DATABASE \"$form->{db}\"|,
                'Sybase' => qq|CREATE DATABASE $form->{db}|,
               'Oracle' => qq|CREATE USER \"$form->{db}\" DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP IDENTIFIED BY \"$form->{db}\"|);

  $dbcreate{Sybase} .= " CHARACTER SET $form->{encoding}" if $form->{encoding};

  $form->{sid} = $form->{dbdefault};
  &dbconnect_vars($form, $form->{dbdefault});
  my $dbh = DBI->connect($form->{dbconnect}, $form->{dbuser}, $form->{dbpasswd}) or $form->dberror;
  my $query = qq|$dbcreate{$form->{dbdriver}}|;
  $dbh->do($query) || $form->dberror($query);

  if ($form->{dbdriver} eq 'Oracle') {
    $query = qq|GRANT CONNECT,RESOURCE TO "$form->{db}"|;
    $dbh->do($query) || $form->dberror($query);
  }
  $dbh->disconnect;


  # setup variables for the new database
  if ($form->{dbdriver} eq 'Oracle') {
    $form->{dbuser} = $form->{db};
    $form->{dbpasswd} = $form->{db};
  }

  &dbconnect_vars($form, $form->{db});

  $dbh = DBI->connect($form->{dbconnect}, $form->{dbuser}, $form->{dbpasswd}) or $form->dberror;

  # create the tables
  my $dbdriver = ($form->{dbdriver} =~ /Pg/) ? 'Pg' : $form->{dbdriver};

  my $filename = qq|sql/${dbdriver}-tables.sql|;
  $self->process_query($form, $dbh, $filename);

  # create functions
  $filename = qq|sql/${dbdriver}-functions.sql|;
  $self->process_query($form, $dbh, $filename);

  # load gifi
  ($filename) = split /_/, $form->{chart};
  $filename =~ s/_//;
  $self->process_query($form, $dbh, "sql/${filename}-gifi.sql");

  # load chart of accounts
  $filename = qq|sql/$form->{chart}-chart.sql|;
  $self->process_query($form, $dbh, $filename);

  # load mimetypes
  $filename = qq|sql/Mimetype.sql|;
  $self->process_query($form, $dbh, $filename);

  # create indices
  $filename = qq|sql/${dbdriver}-indices.sql|;
  $self->process_query($form, $dbh, $filename);

  # create custom tables and functions
  for my $f (qw(tables functions)) {
    $filename = "sql/${dbdriver}-custom_${f}.sql";
    $self->process_query($form, $dbh, $filename);
  }

  $query = qq|INSERT INTO defaults (fldname, fldvalue)
              VALUES (?, ?)|;
  my $sth = $dbh->prepare($query);

  $sth->execute('company', $form->{company});
  $sth->finish;

  $sth->execute('roundchange', 0.01);
  $sth->finish;

  $dbh->disconnect;

  1;

}



sub process_query {
  my ($self, $form, $dbh, $filename) = @_;

  return unless (-f $filename);

  open(FH, "$filename") or $form->error("$filename : $!\n");
  my $query = "";
  my $loop = 0;
  my $i;

  while (<FH>) {
    $i++;

    if ($loop && /^--\s*end\s*(procedure|function|trigger)/i) {
      $loop = 0;
      $dbh->do($query);

      if ($errstr = $DBI::errstr) {
        $form->info("$filename:$i - $errstr\n");
      }
      $query = "";
      next;
    }

    if ($loop || /^create *(or replace)? *(procedure|function|trigger)/i) {
      $loop = 1;
      next if /^(--.*|\s+)$/;

      $query .= $_;
      next;
    }

    # don't add comments or empty lines
    next if /^(--.*|\s+)$/;

    # anything else, add to query
    $query .= $_;

    if (/;\s*$/) {
      # strip ;... Oracle doesn't like it
      $query =~ s/;\s*$//;
      $query =~ s/\\'/''/g;

      $dbh->do($query);

      if ($errstr = $DBI::errstr) {
        $form->info("$filename:$i - $errstr\n");
      }

      $query = "";
    }

  }
  close FH;

}



sub dbdelete {
  my ($self, $form) = @_;

  $form->{db} =~ s/;//g;

  my %dbdelete = ( 'Pg' => qq|DROP DATABASE "$form->{db}"|,
                'Sybase' => qq|DROP DATABASE $form->{db}|,
               'Oracle' => qq|DROP USER $form->{db} CASCADE|
                 );

  $form->{sid} = $form->{dbdefault};
  &dbconnect_vars($form, $form->{dbdefault});
  my $dbh = DBI->connect($form->{dbconnect}, $form->{dbuser}, $form->{dbpasswd}) or $form->dberror;
  my $query = qq|$dbdelete{$form->{dbdriver}}|;
  $dbh->do($query) || $form->dberror($query);

  $dbh->disconnect;

}


sub dbupdate {
  my ($self, $form) = @_;

  $form->{sid} = $form->{dbdefault};

  my @upgradescripts = ();
  my @upgradescripts2 = ();
  my $query;

  # read update scripts into memory
  opendir SQLDIR, "sql/." or $form->error($!);
  @upgradescripts = sort script_version grep /$form->{dbdriver}-upgrade-.*?\.sql$/, readdir SQLDIR;
  rewinddir SQLDIR;
  @upgradescripts2 = grep /Tekki-upgrade-.*\.sql$/, readdir SQLDIR;
  closedir SQLDIR;

  &dbconnect_vars($form, $form->{dbname});

  my $dbh = DBI->connect($form->{dbconnect}, $form->{dbuser}, $form->{dbpasswd}) or $form->dberror;

  # check version
  $query = qq|SELECT * FROM defaults|;
  my $sth = $dbh->prepare($query);
  $sth->execute || $form->dberror($query);

  my %defaults;
  my $version;
  my $version2;

  if ($sth->{NAME}->[0] eq 'fldname') {
    %defaults = $form->get_defaults($dbh, \@{['version', 'version2']});
    $version = $defaults{version};
    $version2 = $defaults{version2} * 1;
  } else {
    $query = qq|SELECT version FROM defaults|;
    ($version) = $dbh->selectrow_array($query);
  }
  $sth->finish;

  $version = calc_version($version);
  my $dbversion = calc_version($form->{dbversion});

  foreach my $upgradescript (@upgradescripts) {
    my $us = $upgradescript;
    $us =~ s/(^$form->{dbdriver}-upgrade-|\.sql$)//g;

    my ($mindb, $maxdb) = split /-/, $us;
    $mindb = calc_version($mindb);
    $maxdb = calc_version($maxdb);

    next if ($version >= $maxdb);

    # exit if there is no upgrade script or version == mindb
    last if ($version < $mindb || $version >= $dbversion);

    # apply upgrade
    $self->process_query($form, $dbh, "sql/$upgradescript");

    $version = $maxdb;

  }

  # Tekki upgrade
  for my $upgradescript (@upgradescripts2) {
    $upgradescript =~ /Tekki-upgrade-(\d+)-(\d+)/;
    my $mindb = $1 * 1;
    my $maxdb = $2 * 1;

    next if ($version2 >= $maxdb);

    last if ($version2 >= $form->{dbversion2});

    # apply upgrade
    $self->process_query($form, $dbh, "sql/$upgradescript");

    $version2 = $maxdb;
  }

  $dbh->disconnect;

}


sub dbpassword {
  my ($self, $form) = @_;

  &dbconnect_vars($form, $form->{dbname});

  my $dbh = DBI->connect($form->{dbconnect}, $form->{dbuser}, $form->{dbpasswd}) or $form->dberror;

  my $query;

  if ($form->{new_password}) {
    $query = qq|ALTER ROLE '$form->{dbuser}' WITH PASSWORD '$form->{new_password}'|;
  } else {
    $query = qq|ALTER ROLE '$form->{dbuser}' WITH PASSWORD NULL|;
  }

  $dbh->do($query) or $form->dberror($query);

  $dbh->disconnect;

}


sub calc_version {

  my @v = split /\./, $_[0];
  my $version = 0;
  my $i;

  for ($i = 0; $i <= $#v; $i++) {
    $version *= 1000;
    $version += $v[$i];
  }

  return $version;

}


sub script_version {
  my ($my_a, $my_b) = ($a, $b);

  my ($a_from, $a_to, $b_from, $b_to);
  my ($res_a, $res_b, $i);

  $my_a =~ s/.*-upgrade-//;
  $my_a =~ s/.sql$//;
  $my_b =~ s/.*-upgrade-//;
  $my_b =~ s/.sql$//;
  ($a_from, $a_to) = split(/-/, $my_a);
  ($b_from, $b_to) = split(/-/, $my_b);

  $res_a = calc_version($a_from);
  $res_b = calc_version($b_from);

  if ($res_a == $res_b) {
    $res_a = calc_version($a_to);
    $res_b = calc_version($b_to);
  }

  return $res_a <=> $res_b;

}


sub create_config {
  my ($self, $filename) = @_;

  $self->{dbpasswd} = unpack 'u', $self->{dbpasswd};

  my $dbh = DBI->connect($self->{dbconnect}, $self->{dbuser}, $self->{dbpasswd});
  $self->error($DBI::errstr) unless $dbh;

  my $id;
  my %acs;
  my $login = $self->{login};
  $login =~ s/@.*//;

  $query = qq|SELECT e.id, e.acs, a.acs
              FROM employee e
              LEFT JOIN acsrole a ON (e.acsrole_id = a.id)
              WHERE login = '$login'|;
  ($id, $acs{acs}, $acs{role}) = $dbh->selectrow_array($query);

  $dbh->disconnect;

  if (!$id) {
    return if $login ne 'admin';
  }

  $acs{acs} .= ";$acs{role}";
  for (split /;/, $acs{acs}) {
    $acs{$_} = 1;
  }
  delete $acs{""};
  delete $acs{acs};
  delete $acs{role};

  $self->{acs} = join ';', sort keys %acs;

  my $password = $self->{password};
  my $key = "";
  my $login;

  $self->{sessionkey} = "";
  $self->{sessioncookie} = "";

  if ($self->{password}) {
    my $t = time + $self->{timeout};
    srand( time() ^ ($$ + ($$ << 15)) );
    $login = $self->{login};
    $login =~ s/(\@| )/_/g;
    $key = "$login$self->{password}$t";

    my $i = 0;
    my $l = length $key;
    my $j = $l;
    my %ndx = ();
    my $pos;

    while ($j > 0) {
      $pos = int rand($l);
      next if $ndx{$pos};
      $ndx{$pos} = 1;
      $self->{sessioncookie} .= substr($key, $pos, 1);
      $self->{sessionkey} .= substr("0$pos", -2);
      $j--;
    }

    $self->{password} = crypt $self->{password}, substr($self->{login}, 0, 2) if ! $self->{encrypted};
  }

  $self->{dbpasswd} = pack 'u', $self->{dbpasswd};
  chomp $self->{dbpasswd};

  umask(002);
  open(CONF, '>', $filename) or $self->error("$filename : $!");

  # create the config file
  print CONF qq|# configuration file for $self->{login}
use utf8;

\%myconfig = (
|;

  for (&config_vars) {

    $self->{$_} =~ s/\\/\\\\/g;
    $self->{$_} =~ s/'/\\'/g;

    print CONF qq|  $_ => '$self->{$_}',\n| if $self->{$_};
    $self->{$_} =~ s/\\\\/\\/g;
    $self->{$_} =~ s/\\'/'/g;
  }

  print CONF qq|);\n\n|;

  close CONF;

  $self->{password} = $password;

  1;

}


sub save_member {
  my ($self, $memberfile, $userspath) = @_;

  # format dbconnect and dboptions string
  &dbconnect_vars($self, $self->{dbname});

  $self->error("$memberfile locked!") if (-f "${memberfile}.LCK");
  open(FH, ">${memberfile}.LCK") or $self->error("${memberfile}.LCK : $!");
  close(FH);

  if (! open(CONF, '+<:utf8', $memberfile)) {
    unlink "${memberfile}.LCK";
    $self->error("$memberfile : $!");
  }

  @config = <CONF>;

  seek(CONF, 0, 0);
  truncate(CONF, 0);

  while ($line = shift @config) {
    last if ($line =~ /^\[$self->{login}\]/);
    print CONF $line;
  }

  # remove everything up to next login or EOF
  while ($line = shift @config) {
    last if ($line =~ /^\[/);
  }

  # this one is either the next login or EOF
  print CONF $line;

  while ($line = shift @config) {
    print CONF $line;
  }

  print CONF qq|[$self->{login}]\n|;

  if ($self->{packpw}) {
    $self->{dbpasswd} = pack 'u', $self->{dbpasswd};
    chomp $self->{dbpasswd};
  }

  my $password = $self->{password};
  if (!$self->{encrypted}) {
    if ($self->{password}) {
      srand( time() ^ ($$ + ($$ << 15)) );
      $self->{password} = crypt $self->{password}, substr($self->{login}, 0, 2);
    }
  }

  if ($self->{'root login'}) {
    @config = qw(password);
  } else {
    @config = &config_vars;
    @config = grep !/^session/, @config;
  }

  # replace \r\n with \n
  $self->{signature} =~ s/\r?\n/\\n/g;

  for (sort @config) { print CONF qq|$_=$self->{$_}\n| if $self->{$_} }

  print CONF "\n";
  close CONF;
  unlink "${memberfile}.LCK";

  # unlink conf file
  if (! $self->{'root login'}) {
    $self->{password} = $password;
    $self->create_config("$userspath/$self->{login}.conf");
  }

}


sub delete_login {
  my ($self, $form) = @_;

  my $dbh = DBI->connect($form->{dbconnect}, $form->{dbuser}, $form->{dbpasswd}, {AutoCommit} => 0) or $form->dberror;

  my $login = $form->{login};
  $login =~ s/@.*//;
  my $query = qq|SELECT id FROM employee
                 WHERE login = '$login'|;
  my ($id) = $dbh->selectrow_array($query);

  my $query = qq|UPDATE employee SET
                 login = NULL,
                 enddate = current_date
                 WHERE login = '$login'|;
  $dbh->do($query);

  $query = qq|UPDATE report SET
                 login = ''
                 WHERE login = '$login'|;
  $dbh->do($query);

  $dbh->commit;
  $dbh->disconnect;

}


sub config_vars {

  my @conf = qw(acs countrycode charset dateformat
             dbconnect dbdriver dbhost dbname dboptions dbpasswd
             dbport dbuser menuwidth name email emailcopy numberformat password
             outputformat printer sessionkey sid
             signature stylesheet tan templates timeout vclimit);

  @conf;

}


sub encoding {
  my ($self, $dbdriver) = @_;

  my %encoding = ( Pg => 'UTF8--Unicode (UTF-8)' );
  # qq|
# SQL_ASCII--ASCII
# UTF8--Unicode (UTF-8)
# EUC_JP--Japanese (EUC_JP)
# EUC_JP--Japanese (EUC_JIS_2004)
# SJIS--Japanese (SJIS)
# SHIFT_JIS_2004--Japanese (SHIFT_JIS_2004)
# EUC_KR--Korean
# JOHAB--Korean (Hangul)
# UHC--Korean (Unified Hangul Code)
# EUC_TW--Taiwanese
# BIG5--Traditional Chinese (BIG5)
# EUC_CN--Simplified Chinese (GB18030)
# GBK--Simplified Chinese (GBK)
# GB18030--Chinese
# KOI8R--Cyrillic (Russian)
# KOI8U--Cyrillic (Ukrainian)
# LATIN1--ISO 8859-1 Western Europe
# LATIN2--ISO 8859-2 Central Europe
# LATIN3--ISO 8859-3 South Europe
# LATIN4--ISO 8859-4 North Europe
# LATIN5--ISO 8859-9 Turkish
# LATIN6--ISO 8859-10 Nordic
# LATIN7--ISO 8859-13 Baltic
# LATIN8--ISO 8859-14 Celtic
# LATIN9--ISO 8859-15 (Latin 1 with Euro and accents)
# LATIN10--ISO 8859-16 Romanian
# ISO_8859_5--ISO 8859-5/ECMA 113 (Latin/Cyrillic)
# ISO_8859_6--ISO 8859-6/ECMA 114 (Latin/Arabic)
# ISO_8859_7--ISO 8859-7/ECMA 118 (Latin/Greek)
# ISO_8859_8--ISO 8859-8/ECMA 121 (Latin/Hebrew)
# MULE_INTERNAL--Multilingual Emacs
# WIN866--Windows CP866 (Cyrillic)
# WIN874--Windows CP874 (Thai)
# WIN1250--Windows CP1250 (Central Euope)
# WIN--Windows CP1251 (Cyrillic)
# WIN1252--Windows CP1252 (Western European)
# WIN1253--Windows CP1253 (Greek)
# WIN1254--Windows CP1254 (Turkish)
# WIN1255--Windows CP1255 (Hebrew)
# WIN1256--Windows CP1256 (Arabic)
# WIN1257--Windows CP1257 (Baltic)
# WIN1258--Windows CP1258 (Vietnamese)|
#  );

  $encoding{$dbdriver};

}


sub error {
  my ($self, $msg) = @_;

  if ($ENV{HTTP_USER_AGENT}) {
    print "Content-Type: text/html\n\n";
  }
  print $msg;
  die "Error: $msg\n";

}


sub add_db_size {
  my ($form, $members) = @_;

  my %dbhosts;
  for my $member (values %$members) {
    my $hostcode = "$member->{dbhost}$member->{dbport}$member->{dbuser}";

    $dbhosts{$hostcode} ||= {$member->%*};
    push $dbhosts{$hostcode}{dbnames}->@*, $member->{dbname};
  }

  my $query = qq|
    SELECT pg_size_pretty(pg_database_size(?))
    WHERE EXISTS (SELECT 1 FROM pg_catalog.pg_database WHERE datname = ?)|;

  for my $dbhost (values %dbhosts) {
    $dbhost->{dbpasswd} = unpack 'u', $dbhost->{dbpasswd};
    my $dbh = $form->dbconnect($dbhost);

    for my $dbname ($dbhost->{dbnames}->@*) {
      ($members->{$dbname}{size}) = $dbh->selectrow_array($query, undef, $dbname, $dbname);
    }

    $dbh->disconnect;
  }
}

1;

=encoding utf8

=head1 NAME

User - User related functions

=head1 DESCRIPTION

L<SL::User> contains the user related functions.

=head1 CONSTRUCTOR

L<SL::User> uses the following constructor:

=head2 new

  $user = User->new($memfile, $login);

=head1 FUNCTIONS

L<SL::User> implements the following functions:

=head2 add_db_size

  User::add_db_size($form, $members);

=head2 calc_version

  User::calc_version($version);

=head2 config_vars

  User::config_vars;

=head2 country_codes

  User::country_codes;

=head2 dbconnect_vars

  User::dbconnect_vars($form, $db);

=head2 dbdrivers

  User::dbdrivers;

=head2 script_version

  User::script_version($my_a, $my_b);

=head1 METHODS

L<SL::User> implements the following methods:

=head2 check_recurring

  $user->check_recurring($form);

=head2 create_config

  $user->create_config($filename);

=head2 dbcreate

  $user->dbcreate($form);

=head2 dbdelete

  $user->dbdelete($form);

=head2 dbpassword

  $user->dbpassword($form);

=head2 dbsources

  $user->dbsources($form);

=head2 dbupdate

  $user->dbupdate($form);

=head2 delete_login

  $user->delete_login($form);

=head2 encoding

  $user->encoding($dbdriver);

=head2 error

  $user->error($msg);

=head2 login

  $user->login($form, $userspath);

=head2 logout

  $user->logout($myconfig, $form);

=head2 process_query

  $user->process_query($form, $dbh, $filename);

=head2 save_member

  $user->save_member($memberfile, $userspath);

=cut
