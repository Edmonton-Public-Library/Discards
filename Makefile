# copies most rescent files from eplapp for updating to git.
SERVER=eplapp.library.ualberta.ca
# SERVER=edpl-t.library.ualberta.ca
USER=sirsi
REMOTE=~/Unicorn/EPLwork/anisbet/
LOCAL=~/projects/discards/
LIBS=~/projects/
APP=discard.pl
EPL=epl.pm

put: test
	scp ${LOCAL}${APP} ${USER}@${SERVER}:${REMOTE}
	scp ${LOCAL}${EPL} ${USER}@${SERVER}:${REMOTE}
get:
	scp ${USER}@${SERVER}:${REMOTE}${APP} ${LOCAL}
test: copy
	perl -c ${LOCAL}${APP}
copy: ${LIBS}${EPL}
	cp ${LIBS}${EPL} ${LOCAL}