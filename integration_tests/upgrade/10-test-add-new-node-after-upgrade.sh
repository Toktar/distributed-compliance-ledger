#!/bin/bash
# Copyright 2020 DSR Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail
source integration_tests/cli/common.sh

localnet_dir=".localnet"
dcl_user_home="/var/lib/dcl"
DCL_DIR="$dcl_user_home/.dcl"

node_p2p_port=26570
node_client_port=26571
chain_id="dclchain"
ip="192.167.10.28"
docker_network="distributed-compliance-ledger_localnet"

MASTER_UPGRADE_DOCKERFILE="./integration_tests/upgrade/Dockerfile-build-master"
MASTER_UPGRADE_IMAGE="dcld-build-master"
MASTER_UPGRADE_CONTAINER_NAME="$MASTER_UPGRADE_IMAGE-inst"

# DCLD_VERSION="$(docker run "$MASTER_UPGRADE_IMAGE" /bin/sh -c "cd /go/src/distributed-compliance-ledger && git rev-parse --short HEAD")"

DCLD_BIN="/tmp/dcld_bins/dcld_master"

function check_expected_catching_up_status_for_interval {
    local expected_status="$1"
    local overall_ping_time_sec="${2:-100}"
    local process_alive="${3:-}"
    local seconds=0
    local status_substring="\"catching_up\":$expected_status"

    while [ $seconds -lt $overall_ping_time_sec ]; do
        sleep 1
        local seconds=$((seconds+1))

        if [ $( docker container ls -a | grep "$NEW_OBSERVER_CONTAINER_NAME" | wc -l ) -eq 0 ]; then
            continue
        fi

        if ! docker container inspect "$NEW_OBSERVER_CONTAINER_NAME" | grep -q '"Status": "running"'; then
            continue
        fi

        if [[ $(docker exec --user root "$NEW_OBSERVER_CONTAINER_NAME" dcld status 2>&1) == *"$status_substring"* ]]; then
            return 0
        fi
         if [[ -n "$process_alive" ]]; then
            if ! docker exec "$NEW_OBSERVER_CONTAINER_NAME" ps -A | grep -q "$process_alive"; then
                echo "error: process $process_alive is not found"
                return 1
            fi
        fi
    done

    return 1
}

function check_expected_version_for_interval {
    local expected_version="$1"
    local overall_ping_time_sec="${2:-10}"
    local process_alive="${3:-}"
    local seconds=0

    while [ $seconds -lt $overall_ping_time_sec ]; do
        sleep 1
        local seconds=$((seconds+1))

        if [ $( docker container ls -a | grep "$NEW_OBSERVER_CONTAINER_NAME" | wc -l ) -eq 0 ]; then
            continue
        fi

        if ! docker container inspect "$NEW_OBSERVER_CONTAINER_NAME" | grep -q '"Status": "running"'; then
            continue
        fi

        if [ $(docker exec "$NEW_OBSERVER_CONTAINER_NAME" dcld version 2>&1) == "$expected_version" ]; then
            return 0
        fi

        if [[ -n "$process_alive" ]]; then
            if ! docker exec "$NEW_OBSERVER_CONTAINER_NAME" ps -A | grep -q "$process_alive"; then
                echo "error: process $process_alive is not found"
                return 1
            fi
        fi
    done

    return 1
}

cleanup_container $NEW_OBSERVER_CONTAINER_NAME

echo "1. Run \"$NEW_OBSERVER_CONTAINER_NAME\" container"
docker run -d --name "$NEW_OBSERVER_CONTAINER_NAME" --ip $ip -p "$node_p2p_port-$node_client_port:26656-26657" --network $docker_network -i dcledger

test_divider

echo "2. Install dcld to \"$NEW_OBSERVER_CONTAINER_NAME\""
docker cp "$DCLD_BIN" "$NEW_OBSERVER_CONTAINER_NAME":"$dcl_user_home"/dcld

# test_divider

echo "3. Set up configuration files for \"$NEW_OBSERVER_CONTAINER_NAME\""
docker exec "$NEW_OBSERVER_CONTAINER_NAME" ./dcld init "$NEW_OBSERVER_CONTAINER_NAME" --chain-id $chain_id
docker cp "$localnet_dir/node0/config/genesis.json" $NEW_OBSERVER_CONTAINER_NAME:$DCL_DIR/config
peers="$(cat "$localnet_dir/node0/config/config.toml" | grep -o -E "persistent_peers = \".*\"")"
docker exec "$NEW_OBSERVER_CONTAINER_NAME" sed -i "s/persistent_peers = \"\"/$peers/g" $DCL_DIR/config/config.toml
docker exec "$NEW_OBSERVER_CONTAINER_NAME" sed -i 's/laddr = "tcp:\/\/127.0.0.1:26657"/laddr = "tcp:\/\/0.0.0.0:26657"/g' $DCL_DIR/config/config.toml

# test_divider

echo "3.1. Set up fast sync for \"$NEW_OBSERVER_CONTAINER_NAME\""
get_height trust_height
trust_height=$(((trust_height / 100) * 100))
trust_hash=$(curl -s http://localhost:26657/commit?height=$trust_height | jq -r '.result.signed_header.commit.block_id.hash')
echo "trust_hash: $trust_hash"
echo "trust_height: $trust_height"

docker exec "$NEW_OBSERVER_CONTAINER_NAME" sed -i 's/^enable = false/enable = true/' $DCL_DIR/config/config.toml
echo "enable: $(docker exec -i "$NEW_OBSERVER_CONTAINER_NAME" cat $DCL_DIR/config/config.toml | grep enable)"
docker exec "$NEW_OBSERVER_CONTAINER_NAME" sed -i "s|^rpc_servers =.*|rpc_servers = \"http://localhost:26657,http://localhost:26657\"|" $DCL_DIR/config/config.toml
echo "rpc_servers: $(docker exec -i "$NEW_OBSERVER_CONTAINER_NAME" cat $DCL_DIR/config/config.toml | grep rpc_servers)"
docker exec "$NEW_OBSERVER_CONTAINER_NAME" sed -i "s|^trust_height =.*|trust_height = $trust_height|" $DCL_DIR/config/config.toml
echo "trust_height: $(docker exec -i "$NEW_OBSERVER_CONTAINER_NAME" cat $DCL_DIR/config/config.toml | grep trust_height)"
docker exec "$NEW_OBSERVER_CONTAINER_NAME" sed -i "s|^trust_hash =.*|trust_hash = \"$trust_hash\"|" $DCL_DIR/config/config.toml
echo "trust_hash: $(docker exec -i "$NEW_OBSERVER_CONTAINER_NAME" cat $DCL_DIR/config/config.toml | grep trust_hash)"

test_divider

echo "4. Locate the app to $DCL_DIR/cosmovisor/genesis/bin directory in \"$NEW_OBSERVER_CONTAINER_NAME\""
docker exec "$NEW_OBSERVER_CONTAINER_NAME" mkdir -p "$DCL_DIR"/cosmovisor/genesis/bin
docker exec "$NEW_OBSERVER_CONTAINER_NAME" cp -f ./dcld "$DCL_DIR"/cosmovisor/genesis/bin/

test_divider

# DCLD_VERSION_NEW="$(docker run "$MASTER_UPGRADE_IMAGE" /bin/sh -c "cd /go/src/distributed-compliance-ledger && git rev-parse --short HEAD")"

# echo "5. Set up version \"$DCLD_VERSION_NEW\" upgrade for \"$NEW_OBSERVER_CONTAINER_NAME\""
# docker cp "$DCLD_BIN_NEW" "$NEW_OBSERVER_CONTAINER_NAME":"$DCL_DIR"/dcld
# docker exec "$NEW_OBSERVER_CONTAINER_NAME" /bin/sh -c "cosmovisor add-upgrade "$DCLD_VERSION_NEW" "$DCL_DIR"/dcld"
# docker rm "$MASTER_UPGRADE_CONTAINER_NAME"

test_divider

echo "6. Start node \"$NEW_OBSERVER_CONTAINER_NAME\""
docker exec "$NEW_OBSERVER_CONTAINER_NAME" sh -c 'rm -rf $DCL_DIR/data'
docker exec -d "$NEW_OBSERVER_CONTAINER_NAME" sh -c "/var/lib/dcl/./node_helper.sh >> /proc/1/fd/1 2>&1"
docker exec "$NEW_OBSERVER_CONTAINER_NAME" ./dcld status || true
docker logs -f "$NEW_OBSERVER_CONTAINER_NAME" &

test_divider

# echo "7. Check dcld version == \"$DCLD_VERSION\" in \"$NEW_OBSERVER_CONTAINER_NAME\""

# check_expected_version_for_interval "$DCLD_VERSION" 10 node_helper || {
#     echo "installed dcld version does not match dcld expected version: $DCLD_VERSION"
#     exit 1
# }

test_divider

overall_ping_time_sec=900

echo "8. Check node \"$NEW_OBSERVER_CONTAINER_NAME\" for START catching up process pinging it every second for $overall_ping_time_sec seconds"

check_expected_catching_up_status_for_interval true $overall_ping_time_sec node_helper || {
    echo "Catch-up procedure does not started"
    exit 1
}

test_divider

echo "9. Check node \"$NEW_OBSERVER_CONTAINER_NAME\" for FINISH catching up process pinging it every second for $overall_ping_time_sec seconds"

check_expected_catching_up_status_for_interval false $overall_ping_time_sec node_helper || {
    echo "Catch-up procedure does not finished"
    exit 1
}

test_divider

# echo "10. Check node \"$NEW_OBSERVER_CONTAINER_NAME\" dcld updated to version \"$DCLD_VERSION_NEW\""

# check_expected_version_for_interval "$DCLD_VERSION_NEW" || {
#     echo "updated dcld version does not match dcld expected version"
#     exit 1
# }

echo "Add new node after upgrade PASSED"