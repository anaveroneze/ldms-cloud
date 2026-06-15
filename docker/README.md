# LDMS Cluster — Docker Compose

Runs the full LDMS cluster (1 aggregator + N samplers) as containers on a single machine. No AWS provisioning, SSM, or S3 required.

## Prerequisites

- ~15 minutes for the first build (compiles LDMS from source)
- AWS CloudShell has Docker but not `docker-compose` — install it first:

```bash
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version
```

## Usage

```bash
cd docker/
# Build the LDMS image (once; reuse on subsequent runs)
docker-compose build

# Start the cluster (1 aggregator + 2 samplers)
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0
docker-compose up
docker-compose exec aggregator ldms_ls -x sock -p 10444 -h localhost -v

# Scale to more samplers
docker-compose up --scale sampler=3
docker-compose exec aggregator ldms_ls -x sock -p 10444 -h localhost -v

docker cp $(docker-compose ps -q aggregator):/data/ldms-csv ./ldms-data
ls ldms-data/
less ldms-data/ldms_data/meminfo

# Stop and remove containers
docker-compose down
```

## Configuration

Edit `agg.conf` or `sampler.conf` directly — they are mounted into the containers at runtime, so changes take effect on the next `docker-compose up` without rebuilding the image.

## Differences from the EC2 workflow

|   | EC2 workflow | Docker workflow |
|---|---|---|
| Infrastructure | 3 EC2 instances | 1 machine (local or EC2) |
| Aggregator address | `aggregator.cluster.internal` | `aggregator` (Compose DNS) |
| CSV output | `/home/ubuntu/ldms-csv` | Docker volume `/data/ldms-csv` |
| Scaling | `NUM_SAMPLERS` + relaunch | `--scale sampler=N` |
| Setup time | ~15 min (compile per launch) | ~15 min once, then instant |
