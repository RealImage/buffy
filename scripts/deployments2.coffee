# Description:
#   Handles OpsWorks deployments.
#
# Commands:
#   hubot deploy somebranch to testing
#   hubot deploy master to prod
#
# Events:
#   None

AWS = require 'aws-sdk'
AWS.config.update {
  accessKeyId: process.env.AWS_ACCESS_KEY_ID,
  secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY
}
_ = require 'underscore'
_s = require 'underscore.string'
defer = require 'simply-deferred'
util = require 'util'

autoscaling = new AWS.AutoScaling region: 'ap-southeast-1'



deploy = (msg) ->
  groupName = '201402092305-moviebuff-fullstack'
  autoscaling.describeAutoScalingGroups {AutoScalingGroupNames: [groupName]}, (err, data) ->
    instancesInService =  _.select data.AutoScalingGroups[0].Instances, (instance) -> instance.LifecycleState == 'InService'
    startingInstances = data.AutoScalingGroups[0].Instances.length
    doubleInstances = startingInstances * 2
    msg.send "Found #{startingInstances} instances currently in service, setting to #{doubleInstances}..."
    autoscaling.updateAutoScalingGroup {
      AutoScalingGroupName: groupName,
      DesiredCapacity: doubleInstances
    }, (err, data) ->
      if err then msg.send util.inspect err
    finishedDoubling = new defer.Deferred()
    runningCheck = setInterval ->
      autoscaling.describeAutoScalingGroups {AutoScalingGroupNames: [groupName]}, (err, data) ->
        instancesCurrentlyInService =  _.select data.AutoScalingGroups[0].Instances, (instance) -> instance.LifecycleState == 'InService'
        msg.send "#{instancesCurrentlyInService.length} instances now in service..."
        if instancesCurrentlyInService.length == doubleInstances
          clearInterval runningCheck
          finishedDoubling.resolve()
    , 10000

    finishedDoubling.done ->
      msg.send "Vertex reached. Dropping old instances now: restoring back to #{startingInstances}..."
      autoscaling.updateAutoScalingGroup {
        AutoScalingGroupName: groupName,
        DesiredCapacity: startingInstances
      }, (err, data) ->
        if err then msg.send util.inspect err
        msg.send "Done. Bounce Complete."



module.exports = (robot) ->
  robot.respond /bounce/i, deploy


