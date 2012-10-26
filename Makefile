# copies most rescent files from eplapp for updating to git.
SERVER=eplapp.library.ualberta.ca
# SERVER=edpl-t.library.ualberta.ca
USER=sirsi
REMOTE=~/Unicorn/EPLwork/anisbet/
LOCAL=~/projects/discards/
APP=discard.pl

put: test
	scp ${LOCAL}${APP} ${USER}@${SERVER}:${REMOTE}
get:
	scp ${USER}@${SERVER}:${REMOTE}${APP} ${LOCAL}
test:
	perl -c ${LOCAL}${APP}