unit uVersion;

{$mode objfpc}{$H+}

// Source unique de verite pour la version: lue aussi par scripts/make-app.sh
// (Info.plist) et par la CI. Ne pas dupliquer ailleurs.

interface

const
  RSSH_APP_NAME = 'RottenSSHrimp';
  RSSH_VERSION  = '1.2';
  RSSH_SLOGAN   = 'A rotten approach to remote administration.';
  RSSH_LICENSE  = 'GPL-3.0-or-later';
  RSSH_URL      = 'https://github.com/clamy54/RottenSSHrimp';

implementation

end.
