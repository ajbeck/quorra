---
title: "Command reference"
description: "Every quorra subcommand, its arguments and its options."
weight: 20
---
Every command except `version` needs the Quorra app running.

## quorra profiles

### list

Lists the profiles managed by the running app.

```console
$ quorra profiles list
NAME                   SESSION       REGION     ACCOUNT       ROLE
ac:cp:org_admin        astrocompute  us-east-2  111122223333  OrgAdmin
ac:mgmt:admin          astrocompute  us-east-2  444455556666  Admin
```

`--format` takes `table` (the default), `names` or `json`. Use `names` when piping into another command:

```console
$ quorra profiles list --format names
ac:cp:org_admin
ac:mgmt:admin
```

### sign-in

Signs in to the Identity Center session a profile depends on. Takes the profile name.

```console
$ quorra profiles sign-in ac:cp:org_admin
```

## quorra imds

Every endpoint argument accepts a name, a UUID, or `default` for the default endpoint.

### list

Lists the endpoints the app manages.

```console
$ quorra imds list
STATUS   ADDRESS               PROFILE          NAME
running  169.254.169.254:80    ac:cp:org_admin  Default IMDS Endpoint
stopped  127.0.0.1:9678        ac:mgmt:admin    localhost:9678
```

`--format` takes `table` (the default) or `json`.

### status

Shows the current state of one endpoint. Takes the endpoint, and the same `--format` options as `list`.

```console
$ quorra imds status default
```

### start, stop

Start or stop one endpoint.

```console
$ quorra imds start default
$ quorra imds stop localhost:9678
```

### switch-profile

Changes the profile an endpoint serves. Takes the profile name; `--endpoint` picks which endpoint, defaulting to `default`.

```console
$ quorra imds switch-profile ac:mgmt:admin
Default IMDS Endpoint now uses ac:mgmt:admin.
```

The default endpoint can be switched while it is running.

## quorra start, quorra stop

Start or stop the Quorra app itself.

## quorra version

Prints the version. The only command that does not need the app running.
