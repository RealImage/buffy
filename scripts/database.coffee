# Description:
#   Handles operations on the Moviebuff database systems.
#
# Commands:
#   hubot copy prod
#
# Events:
#   None

AWS = require 'aws-sdk'
AWS.config.update {
  accessKeyId: process.env.AWS_ACCESS_KEY_ID,
  secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY
}
_ = require 'underscore'
defer = require 'simply-deferred'
util = require 'util'

rds = new AWS.RDS({
  apiVersion: '2013-09-09'
  region: 'ap-southeast-1'
})

waitTillAvailable = (dbIdentifier) ->
  completionDeferred = new defer.Deferred()
  completionCheck = setInterval ->
    rds.describeDBInstances {DBInstanceIdentifier: dbIdentifier}, (err, data) ->
      if !err && data.DBInstances[0] && data.DBInstances[0].DBInstanceStatus == 'available'
        completionDeferred.resolve data.DBInstances[0]
        clearInterval completionCheck
  , 3000
  completionDeferred.promise()

waitTillSnapshotAvailable = (snapshotId) ->
  completionDeferred = new defer.Deferred()
  completionCheck = setInterval ->
    rds.describeDBSnapshots {DBSnapshotIdentifier: snapshotId}, (err, data) ->
      if !err && data.DBSnapshots[0] && data.DBSnapshots[0].Status == 'available'
        completionDeferred.resolve data.DBSnapshots[0]
        clearInterval completionCheck
  , 3000
  completionDeferred.promise()

module.exports = (robot) ->
  robot.respond /snap prod/i, (msg) ->
    steps = {
      statusCheck: new defer.Deferred()
      deleteTesting: new defer.Deferred(),
      createSnapshot: new defer.Deferred(),
      restoreSnapshot: new defer.Deferred(),
      establishNewTesting: new defer.Deferred()
    }

    date = new Date()
    snapshotId = "moviebuff-pgbackup-#{date.toISOString().split('.')[0].replace(/\:/g,'-')}"

    rds.describeDBInstances {DBInstanceIdentifier: 'moviebuff-prod-post'}, (err, data) ->
      if !err && data.DBInstances[0] && data.DBInstances[0].DBInstanceStatus == 'available' then steps.statusCheck.resolve() else steps.statusCheck.reject()
    
    steps.statusCheck.fail -> msg.send "Status check failed."

    steps.statusCheck.done ->
      rds.createDBSnapshot {DBInstanceIdentifier: 'moviebuff-prod-post', DBSnapshotIdentifier: snapshotId}, (err, data) ->
        if !err then msg.send('Snapshotting PROD now...') else msg.send err.message
      waitTillSnapshotAvailable(snapshotId).done -> 
        msg.send "Snapshotted: #{snapshotId}"
        steps.createSnapshot.resolve()

  robot.respond /restore (.*)?/i, (msg) ->
    snapshotId = msg.match[1]  
    deleteTesting = new defer.Deferred()

    rds.deleteDBInstance {DBInstanceIdentifier: 'moviebuff-uat-post', SkipFinalSnapshot: true}, (err, data) ->
      if !err then msg.send('Deleting the current testing DB. The testing environment is going down NOW...') else msg.send err.message
      completionCheck = setInterval ->
        rds.describeDBInstances {DBInstanceIdentifier: 'moviebuff-uat-post'}, (err, data) ->
          if err && err.code == 'DBInstanceNotFound'
            deleteTesting.resolve()
            clearInterval completionCheck
      , 5000

    deleteTesting.done ->    
      rds.restoreDBInstanceFromDBSnapshot {
        DBInstanceIdentifier: 'moviebuff-uat-post',
        DBSnapshotIdentifier: snapshotId,
        AutoMinorVersionUpgrade: true,
        DBInstanceClass: 'db.t1.micro',
        MultiAZ: false,
        PubliclyAccessible: true
      }, (err, data) ->
        if !err then msg.send('Restoring UAT now...') else msg.send err.message
      waitTillAvailable('moviebuff-uat-post').done ->
        msg.send "UAT Restored."




