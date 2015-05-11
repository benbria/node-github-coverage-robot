GitHubApi = require 'github'
Promise   = require 'bluebird'
knox      = require 'knox'
yargs     = require 'yargs'

GITHUB_TOKEN = process.env['GITHUB_ROBOT_ACCESS_TOKEN']
AWS_ACCESS_KEY_ID = process.env['AWS_ACCESS_KEY_ID']
AWS_SECRET_ACCESS_KEY = process.env['AWS_SECRET_ACCESS_KEY']

BRANCH_ENV_VARS = [
    'TRAVIS_BRANCH' # Travis
    'GIT_BRANCH' # Jenkins
    'CIRCLE_BRANCH' # Circle-CI
    'CI_BRANCH' # Codeship
]

SHA_ENV_VARS = [
    'TRAVIS_COMMIT' # Travis
    'GIT_COMMIT' # Jenkins
    'CIRCLE_SHA1' # Circle-CI
    'CI_COMMIT_ID' # Codeship
]

['GITHUB_ROBOT_ACCESS_TOKEN', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY'].forEach (varName) ->
    if !process.env[varName]
        console.error "Environment variable #{varName} should be set."
        process.exit 1

# Create a GitHubApi instance.
makeGitHubApi = ->
    github = new GitHubApi {
        version: '3.0.0'
        protocol: 'https'
        host: 'api.github.com'
        headers: {'user-agent': 'github-coverage'}
    }

    # Promisify the APIs we use
    ['pullRequests', 'issues', 'statuses', 'gitdata'].forEach (api) ->
        Promise.promisifyAll github[api]

    github.authenticate {
        type: 'token'
        token: GITHUB_TOKEN
    }

    return github
github = makeGitHubApi()

parseArguments = ->
    options = yargs.resetOptions()
    .strict()
    .usage """
        Generate coverage status for github commit.
        Usage: $0 --branch [branch] --sha [sha] --bucket [s3Bucket] --project [owner/repo] --coverage [percent]

    """
    .options 'v', {alias: 'verbose',  boolean: true, describe: 'Print verbose details.'}
    .options 'b', {alias: 'branch',                  describe: 'Name of current branch.'}
    .options 's', {alias: 'sha',                     describe: 'SHA of commit to generate a status for.'}
    .options 'bucket', {              demand: true,  describe: 'S3 bucket to upload coverage reports to.'}
    .options 'p', {alias: 'project',  demand: true,  describe: 'Name of github project (e.g. jwalton/robot)'}
    .options 'c', {alias: 'coverage', demand: true,  describe: 'Percentage code coverage from build.'}
    .argv

    [owner, repo] = options.project.split '/'
    if !owner or !repo
        console.error "Invalid project: #{options.project}"
        process.exit 1

    coverage = parseFloat(options.coverage)
    if isNaN coverage
        throw new Error "Invalid coverage number: '#{coverage}' should be a float"

    return {
        verbose: options.verbose
        branch: options.branch
        sha: options.sha
        bucket: options.bucket
        owner,
        repo,
        coverage
    }

getGitParam = (envVars, command) ->
    return new Promise (resolve, reject) ->
        # Fetch value from environment variables if possible
        answer = null
        envVars.forEach (v) ->
            if process.env[v] then answer = process.env[v]
        return resolve answer if answer

        # Go to command line
        childProcess = require 'child_process'
        childProcess.exec command, (err, stdout, stderr) ->
            return reject err if err
            return reject new Error "Unexepcted output in stderr: #{stderr}" if stderr
            answer = stdout.trim()
            resolve answer

getGitSha = -> getGitParam SHA_ENV_VARS, 'git rev-parse HEAD'
getGitBranch = -> getGitParam BRANCH_ENV_VARS, 'git symbolic-ref --short HEAD'

createStatus = (owner, repo, sha, pass, message) ->
    console.log "Creating status for #{sha} - #{pass}"
    github.statuses.createAsync {
        user: owner
        repo
        sha
        state: if pass then 'success' else 'failure'
        description: message
        context: 'git-coverage-robot'
    }

getPrs = (user, repo, {branch}) ->
    github.pullRequests.getAllAsync({
        user,
        repo,
        head: "#{user}:#{branch}"
    })

commentOnPr = (owner, repo, branch, pass, message) ->
    getPrs(owner, repo, {branch})
    .then (prs) ->
        Promise.all prs.map (pr) ->
            # TODO: Check for an existing comment and delete/edit the existing one?
            console.log "Commenting on PR #{pr.number}: #{message}"
            github.issues.createCommentAsync {user: owner, repo, number: pr.number, body: message}

makeS3Client = (bucket) ->
    return knox.createClient {
        key: AWS_ACCESS_KEY_ID
        secret: AWS_SECRET_ACCESS_KEY
        bucket: bucket
    }

s3Filename = (owner, repo) -> "/#{owner}_#{repo}_master_coverage.json"

getMasterData = (s3, owner, repo) ->
    return new Promise (resolve, reject) ->
        s3.getFile s3Filename(owner, repo), (err, res) ->
            return reject err if err

            res.setEncoding 'utf8'
            data = ''
            res.on 'error', (err) -> reject err0
            res.on 'data', (chunk) -> data += chunk
            res.on 'end', ->
                if res.statusCode is 404
                    resolve null
                else if res.statusCode isnt 200
                    return reject new Error "Couldn't get master data: #{res.statusCode}"
                else
                    try
                        data = JSON.parse data
                        resolve data
                    catch err
                        reject err
            res.resume()


# Push coverage data to S3
pushMasterCoverage = (s3, owner, repo, sha, masterData, coverage) ->
    github.gitdata.getCommitAsync {user: owner, repo, sha}
    .then (commit) ->
        if !commit then throw new Error 'Unknown commit: #{sha}'
        commitDate = Date.parse(commit.committer.date)
        if masterData? and commitDate <= masterData.date
            console.log "New master coverage is older than existing master coverage - not pushing."
            return null
        else
            console.log "Pushing coverage report to S3."
            return new Promise (resolve, reject) ->
                data = JSON.stringify {date: commitDate, coverage}
                req = s3.put s3Filename(owner, repo), {
                    'Content-Length': Buffer.byteLength(data)
                    'Content-Type': 'application/json'
                }
                req.on 'response', (res) ->
                    if res.statusCode is 200
                        resolve()
                    else
                        reject new Error "Error uploading data to S3: #{res.statusCode}"
                req.end data

handleCoverageData = ({owner, repo, branch, sha, bucket, coverage}) ->
    s3 = makeS3Client(bucket)

    shaPromise = if !sha then getGitSha() else Promise.resolve(sha)
    branchPromise = if !branch then getGitBranch() else Promise.resolve(branch)

    Promise.all [
        shaPromise,
        branchPromise,
        getMasterData(s3, owner, repo)
    ]
    .then ([sha, branch, masterData]) ->
        jobs = []
        if !masterData
            console.log "No data available from master branch"
        else
            console.log "Master branch coverage is #{masterData.coverage.toFixed(2)}%"
            pass = coverage >= masterData.coverage

            message = if coverage == masterData.coverage
                "Coverage unchanged."
            else
                "Coverage: #{coverage.toFixed(2)}%. Δ from master: #{(coverage - masterData.coverage).toFixed(2)}%"

            # Create a github status.
            jobs.push createStatus(owner, repo, sha, pass, message)

            # If there's a PR, comment on the PR.
            # jobs.push commentOnPr(owner, repo, branch, pass, message)

        # Send data to S3 if this branch is master
        if branch is 'master'
            jobs.push pushMasterCoverage(s3, owner, repo, sha, masterData, coverage)

        return Promise.all jobs

options = parseArguments()
handleCoverageData options
.catch (err) ->
    console.error err.stack ? err