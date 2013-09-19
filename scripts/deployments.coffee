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

opsworks = new AWS.OpsWorks({
  apiVersion: '2013-02-18'
  region: 'us-east-1'
})

deploy = (branch, stackName, msg) ->
  steps = {
    fetchStacks: new defer.Deferred()
    fetchAppInfo: new defer.Deferred()
    updateRevisionOnApp: new defer.Deferred()
    deployApp: new defer.Deferred()
    waitTillDone: new defer.Deferred()
  }
  _.keys(steps).forEach (key) ->
    steps[key].fail (err) -> msg.send "#{key} failed with message: #{err.message}"

  opsworks.describeStacks {}, (err, data) ->
    if err
      steps.fetchStacks.reject err
      return
    stack = _.find data.Stacks, (stack) -> _s.startsWith(stack.Name, "MB-#{stackName}".toUpperCase())
    steps.fetchStacks.resolve stack

  steps.fetchStacks.done (stack) -> msg.send "Initiating deployment for stack: #{stack.Name} (#{stack.StackId})..."

  steps.fetchStacks.done (stack) ->
    opsworks.describeApps {StackId: stack.StackId}, (err, data) ->
      if err
        steps.fetchAppInfo.reject err
        return
      app = data.Apps[0]
      steps.fetchAppInfo.resolve app

  steps.fetchAppInfo.done (app) -> msg.send "Updating the app #{app.Name} (#{app.AppId}) to deploy from the #{branch} branch..."

  steps.fetchAppInfo.done (app) ->
    opsworks.updateApp {AppId: app.AppId, AppSource:{Revision: branch}}, (err, data) ->
      if err
        steps.updateRevisionOnApp.reject err
        return
      opsworks.describeApps {AppIds: [app.AppId]}, (err, data) ->
        if err
          steps.updateRevisionOnApp.reject err
          return
        steps.updateRevisionOnApp.resolve(data.Apps[0])

  steps.updateRevisionOnApp.done (app) -> msg.send "App updated to point to #{app.AppSource.Revision} branch. Starting deployment with migrations..."
  steps.updateRevisionOnApp.done (app) ->
    deploymentOptions = {
      StackId: app.StackId
      AppId: app.AppId
      Command: {
        Name: 'deploy'
        Args: {
          migrate: ["true"]
        }
      }
    }
    opsworks.createDeployment deploymentOptions, (err, data) ->
      if err
        steps.deployApp.reject err
        return
      steps.deployApp.resolve data.DeploymentId, app

  steps.deployApp.done (deploymentId) -> msg.send "Deployment started (#{deploymentId})..."
  steps.deployApp.done (deploymentId, app) ->
    checkStatus = setInterval ->
      opsworks.describeDeployments {DeploymentIds: [deploymentId]}, (err, data) ->
        if !err && data.Deployments && data.Deployments[0]
          info = data.Deployments[0]
          if info.Status == 'successful' then steps.waitTillDone.resolve()
          if info.Status == 'failed' then steps.waitTillDone.reject()
          clearInterval(checkStatus) if info.Status != 'running'
        clearInterval(checkStatus) if err
    , 5000
    setTimeout ->
      clearInterval(checkStatus)
    , (1000 * 60 * 60)


  steps.waitTillDone.done -> msg.send "Finished. #{branch} has been deployed to #{stackName}."

module.exports = (robot) ->
  robot.respond /deploy (.*) to (.*)?/i, (msg) ->
    deploy msg.match[1], msg.match[2], msg


