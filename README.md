# Mon 門 

A small CLI tool written in Zig that wraps `ssh` and allows you to connect to different project environments via a bastion host.

The tool reads a `config.json` file that defines:

* projects
* environments (per project)
* associated users, servers, and container commands
* bastion host 

## Usage

### Connect to a project container shell

```bash
mon shell -p <project> -e <environment> [--no-bastion]
```

Example:

```bash
mon shell -p myapp -e dev
```

This will:

1. Connect to the bastion
2. SSH into the target server
3. Execute the `shell` command defined in `config.json`


### Connect to a project container console

```bash
mon console -p <project> -e <environment> [--no-bastion]
```

Example:

```bash
mon console -p myapp -e prod
```

This runs the `console` command instead of the `shell` one.
