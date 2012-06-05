# copies most rescent files from eplapp for updating to git.
SERVER=eplapp.library.ualberta.ca
USER=sirsi
REMOTE=/s/sirsi/Unicorn/EPLwork/anisbet/
LOCAL=/home/ilsdev/projects/discards/

get:
	scp ${USER}@${SERVER}:${REMOTE}discard.pl ${LOCAL}
	scp ${USER}@${SERVER}:${REMOTE}discard_reports.pl ${LOCAL}
put:
	scp ${LOCAL}discard.pl ${USER}@${SERVER}:${REMOTE}discard_reports.pl 
	scp ${LOCAL}discard_reports.pl ${USER}@${SERVER}:${REMOTE}discard_reports.pl 
