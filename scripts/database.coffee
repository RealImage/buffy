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
  apiVersion: '2013-05-15'
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

module.exports = (robot) ->
  robot.respond /copy prod/i, (msg) ->
    msg.send 'Checking database instances...'
    steps = {
      statusCheck: new defer.Deferred(),
      deleteTesting: new defer.Deferred(),
      createReadReplica: new defer.Deferred(),
      promoteReadReplica: new defer.Deferred(),
      establishNewTesting: new defer.Deferred()
    }

    rds.describeDBInstances {DBInstanceIdentifier: 'mb-production'}, (err, data) ->
      if !err && data.DBInstances[0] && data.DBInstances[0].DBInstanceStatus == 'available' then steps.statusCheck.resolve() else steps.statusCheck.reject()

    steps.statusCheck.fail -> msg.reply "The mb-production database isn't currently up and available. Is something else going on?"
    steps.statusCheck.done -> msg.reply "The production database is ready. Starting the copy now..."

    steps.statusCheck.done ->
      rds.deleteDBInstance {DBInstanceIdentifier: 'mb-uat', SkipFinalSnapshot: true}, (err, data) ->
        if !err then msg.send('Deleting the current testing DB. The testing environment is going down NOW...') else msg.send err.message
        completionCheck = setInterval ->
          rds.describeDBInstances {DBInstanceIdentifier: 'mb-uat'}, (err, data) ->
            if err && err.code == 'DBInstanceNotFound'
              steps.deleteTesting.resolve()
              clearInterval completionCheck
        , 3000

    steps.deleteTesting.done -> msg.reply "The testing DB has been deleted and mb-uat is clear."

    steps.statusCheck.done -> msg.reply("Creating a replica of the production database...")
    steps.statusCheck.done ->
      id = require('crypto').randomBytes(6).toString('hex')
      replicaId = "mb-production-replica-#{id}"
      options = {
        DBInstanceIdentifier: replicaId,
        SourceDBInstanceIdentifier: 'mb-production',
        DBInstanceClass: 'db.t1.micro',
        PubliclyAccessible: true
      }
      rds.createDBInstanceReadReplica options, (err, data) ->
        if !err
          waitTillAvailable(replicaId).done -> steps.createReadReplica.resolve(replicaId)
        else steps.createReadReplica.reject err.message

    steps.createReadReplica.fail (message) -> msg.reply "Creating the production replica failed with the following message: #{message}"
    steps.createReadReplica.done (replicaId) -> msg.reply "The production replica #{replicaId} has been created and is now being promoted..."
    steps.createReadReplica.done (replicaId) ->
      rds.promoteReadReplica {DBInstanceIdentifier: replicaId, BackupRetentionPeriod: 0}, (err, data) ->
        if !err
          waitTillAvailable(replicaId).done -> steps.promoteReadReplica.resolve(replicaId)
        else steps.promoteReadReplica.reject err.message

    steps.promoteReadReplica.fail (message) -> "The promotion of the replica failed with the following message: #{message}"
    steps.promoteReadReplica.done -> msg.reply "The replica has been promoted. Will attempt setting it up as the new testing DB."

    defer.when(steps.promoteReadReplica, steps.deleteTesting).done (replicaId) ->
      options = {
        DBInstanceIdentifier: replicaId,
        DBSecurityGroups: ['mbuatdb', 'default'],
        ApplyImmediately: true,
        BackupRetentionPeriod: 0,
        MultiAZ: false,
        NewDBInstanceIdentifier: 'mb-uat'
      }
      rds.modifyDBInstance options, (err, data) ->
        if !err
          waitTillAvailable('mb-uat').done -> steps.establishNewTesting.resolve()
        else steps.establishNewTesting.reject(err.message)

    steps.establishNewTesting.done -> msg.reply "The production database has been replicated to testing. The testing enviroment should be back up momentarily."
    steps.establishNewTesting.fail -> msg.reply "Setting up the new testing DB failed with the following message: #{message}"
