# barman-recover

Your PostgreSQL PITR backups are only good if you can recover from them.  barman-recover gives you the confidence of daily automated PITR recovery.

barman-recover is a bash program that enables automated and semi-automated recovery and startup of a PGbarman recovery database.  It can be run from cron daily to automatically verify barman PITR recovery.    

After your run the automated recovery from cron, use a nagios-type script to reach out to the database to verify it's running, and optionally warn you if it's not.  You have just verified your daily backup by recovering it, or not, and your process needs work.  

Items to monitor against:

* verify the configured port is listed in netstat
* check postgresql.conf has the same creation date as today's date
  * stat -c %y /var/lib/barman/recovery/20160201T000101/postgresql.conf |awk '{print $1}'
* run a query on your recovered DB
  * psql -p 5555 -c '\dt'
  * check_postgres has a plethora of goodies to check against (http://bucardo.org/check_postgres/)

Features:

* mkdir of proper recovery directories
* avoids conflicts by changing postgresql.conf listen port, data_directory, and log_directory
* supports target-name, target-tli, target-time, and target-xid
* automatic stopping and deletion of colliding recovery databases and datadirs already existing

## Examples:

### manual recovery

* recover server 'thegoods'
* recover the '20171012T000101' backup
* set recovery DB to listen on port 5555
* recover to time 20171012, at 12:01:00.
* recovers into directory /var/lib/barman/recovery/20171012T000101
* Database is fired up (if need be, after old recovery DB is stopped and datadir is nuked)

/usr/local/bin/barman-recover -m -v -a thegoods -b 20171012T000101 -p 5555 -T '2017-10-12 12:01:00 EST'

### automatic recovery

* recover server 'thegoods'
* recover the latest backup as listed in 'barman list-backup thegoods'
* set recovery DB to listen on port 5433
* recovers into directory /var/lib/barman/auto_recovery
* Database is fired up (if need be, after old auto_recovery DB is stopped and datadir is nuked)

/usr/local/bin/barman-recover -r

### get list of available backups

/usr/local/bin/barman-recover -l

### help
/usr/local/bin/barman-recover

## todo

* add a stop and/or delete flag for the recovery database

* add configurable options for auto_recovery and manual recover directory destinations

## GPLv3 License

switched to GPLv3 to be compatible with pgbarman.
