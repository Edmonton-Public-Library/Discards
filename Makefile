# copies most rescent files from eplapp for updating to git.
SERVER=edpl.sirsidynix.net
# SERVER=edpl-t.library.ualberta.ca
USER=sirsi
REMOTE=~/Unicorn/EPLwork/cronjobscripts/Discards/
LOCAL=~/projects/discards/
APP=discard.pl

put: test
	scp ${LOCAL}${APP} ${USER}@${SERVER}:${REMOTE}
test:
	perl -c ${LOCAL}${APP}
test_api:
	perl -c ${LOCAL}${API}
