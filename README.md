Creates a github 'status' for every build which passes only if coverage hasn't fallen compared to master.

How it Works
------------

The basic idea is, you run `github-coverage-robot` as part of your build process.  On `master`
branch, `github-coverage-robot` will upload a small JSON file to Amazon S3 with details about your
code coverage.  After any build, `github-coverage-robot` will fetch the JSON data from S3, and
generate a [github status](https://developer.github.com/v3/repos/statuses/) for the build which
will pass if coverage is as good as or better than master, and fail if it's worse than master.

Usage:
------

Install with:

    npm --save github-coverage-robot

First, create a [github access token](https://github.com/settings/tokens/new) `repo` and
`repo_public` permissions.  Second, create a bucket on S3 to store coverage reports, and obtain
an [AWS access key ID and secret access key](http://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-set-up.html).
On your CI server, set up the following environment variables (note that you should NOT commit
these to source control in an open source project):

    export GITHUB_ROBOT_ACCESS_TOKEN=[github access token]
    export AWS_ACCESS_KEY_ID=[...]
    export AWS_SECRET_ACCESS_KEY=[...]

Then, when running your tests on the CI server, generate your coverage numbers and run:

    ./node_modules/.bin/github-coverage-robot \
        --bucket [s3Bucket] \
        --project [owner/repo] \
        --coverage [percent]

where `s3Bucket` is the name of the bucket you created to hold reports, `owner/repo` is the github
user and repo name for your project, and `percent` is a float value representing the coverage of
your project.  For example:

    ./node_modules/.bin/github-coverage-robot \
        --bucket ci-reports \
        --project benbria/node-github-coverage-robot \
        --coverage 89.34

You can optionally specify `--branch` and `--sha`, but `github-coverage-robot` should be smart
enough to figure them out in most cases.