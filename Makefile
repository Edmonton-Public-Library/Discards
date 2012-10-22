# copies most rescent files from eplapp for updating to git.
SERVER=eplapp.library.ualberta.ca
# SERVER=edpl-t.library.ualberta.ca
USER=sirsi
REMOTE=~/Unicorn/EPLwork/anisbet/
LOCAL=~/projects/discards/

put: test
	scp ${LOCAL}discard.pl ${USER}@${SERVER}:${REMOTE}discard.pl 
	#scp ${LOCAL}discard_reports.pl ${USER}@${SERVER}:${REMOTE}discard_reports.pl 
get:
	scp ${USER}@${SERVER}:${REMOTE}discard.pl ${LOCAL}
	#scp ${USER}@${SERVER}:${REMOTE}discard_reports.pl ${LOCAL}
test:
	perl -c ${LOCAL}discard.pl
	#perl -c ${LOCAL}discard_reports.pl
