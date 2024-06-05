#!/bin/bash

#set -x

APP_ROOT="devtutorial_conf24"
APPS_DIR="/opt/splunk/etc/apps"
USER="admin"
PASSWORD="password"
CI_PROJECT_DIR=${CI_PROJECT_DIR:-`pwd`}
CONTAINER_NAME="splunk"
SPLUNK_VERSION=$1

echo -e "\033[92m Installing docker...\033[0m"
apt-get update
apt-get install docker.io -y

# echo -e "\033[92m Pulling splunk docker image...\033[0m"

echo -e "\033[92m Creating splunk container...\033[0m"
docker run --rm -d -p 8000:8000 -p 8089:8089 -e "SPLUNK_START_ARGS=--accept-license" -e "SPLUNK_PASSWORD=$PASSWORD" --name $CONTAINER_NAME splunk/splunk:$SPLUNK_VERSION

docker ps

echo -e "\033[92m Obtaining Splunk Host Address...\033[0m"
CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")
echo "My splunk instance host: $CONTAINER_IP:8089"

echo -e "\033[92m Waiting for splunk to be up...\033[0m"


echo -e "\033[92m Installing app...\033[0m"
ls -l $CI_PROJECT_DIR
FILE_NAME=$(ls -1 app-dir/)
echo "FILE NAME: $FILE_NAME"
docker exec -i -u root $CONTAINER_NAME mkdir -p $APPS_DIR/$APP_ROOT
echo "docker cp $CI_PROJECT_DIR/app-dir/$FILE_NAME $CONTAINER_NAME:$APPS_DIR"
docker cp $CI_PROJECT_DIR/app-dir/$FILE_NAME $CONTAINER_NAME:$APPS_DIR

docker exec -i $CONTAINER_NAME ls -l /opt/splunk/etc/apps
docker exec -i -u root $CONTAINER_NAME tar -xzvf $APPS_DIR/$FILE_NAME -C $APPS_DIR/
docker exec -i -u root $CONTAINER_NAME chmod -R 777 $APPS_DIR/
docker exec -i $CONTAINER_NAME ls -l $APPS_DIR/
docker exec -i $CONTAINER_NAME ls -l $APPS_DIR/$APP_ROOT/

# docker exec -i $CONTAINER_NAME ls -l $APPS_DIR/$APP_ROOT/bin
# docker exec -i $CONTAINER_NAME cat $APPS_DIR/$APP_ROOT/bin/customadd.py
# docker exec -i $CONTAINER_NAME ls -l $APPS_DIR/$APP_ROOT/default
# docker exec -i $CONTAINER_NAME cat $APPS_DIR/$APP_ROOT/default/commands.conf

echo "Installing python packages"
pip install pytest-splunk-addon

echo "My splunk instance host: $CONTAINER_IP:8000"

# Check running docker containers
echo -e "\033[92m Checking running containers... \033[0m"
docker ps

# Wait for instance to be available
# Waiting for 2 and a half minutes.
loopCounter=30
mainReady=0
checked=0
errors=0

while [[ $loopCounter != 0 && $mainReady != 1 ]]; do
  ((loopCounter--))
  health=`docker ps --filter "name=${version}" --format "{{.Status}}"`
  echo $health

# health will be one of these values: 
  if [[ ! $health =~ "starting" ]]; then

    echo "container running, checking data status..."

    appList=`docker exec -i -u splunk $CONTAINER_NAME bash -c "SPLUNK_USERNAME=$USER SPLUNK_PASSWORD=$PASSWORD /opt/splunk/bin/splunk search '|rest /services/apps/local |table label'"`
    
    echo -e "\033[92m APP LIST: $appList\033[0m"

    if [[ $checked != 1 ]]; then
        echo "Creating HEC token..."
        HEC_TOKEN_OUTPUT=$(docker exec -i -u splunk $CONTAINER_NAME bash -c "SPLUNK_USERNAME=$USER SPLUNK_PASSWORD=$PASSWORD /opt/splunk/bin/splunk http-event-collector create new-token -uri https://$CONTAINER_IP:8089  -disabled 0 -index log")
        HEC_TOKEN=$(echo "$HEC_TOKEN_OUTPUT" | grep -oP 'token=\K[^ ]+')
        echo "Generated token: $HEC_TOKEN"

        echo -e "\033[92m Checking Splunk endpoints...\033[0m"

        echo -e "\033[92m Looking for $APP_ROOT app...\033[0m"
        curl -k -u $USER:$PASSWORD -i -q https://$CONTAINER_IP:8089/services/apps/local/?search=$APP_ROOT | grep $APP_ROOT

        echo -e "\033[92m Running unit tests...\033[0m"

        echo -e "\033[92m Checking if app is installed... \033[0m"
        if ! curl -k -u $USER:$PASSWORD -i -q https://$CONTAINER_IP:8089/services/apps/local/?search=$APP_ROOT | grep -q $APP_ROOT; then
          echo "App $APP_ROOT not found in local apps!"
          # exit 1
          ((errors++))
        fi
        echo -e "\033[92m $APP_ROOT found! \033[0m"

        echo "______________________________________________________________________"

        echo -e "\033[92m Checking if custom search command runs correctly... \033[0m"
        echo -e "\033[92m Adding 2 to 999 and expecting 1001... \033[0m"

        docker exec -i -u splunk $CONTAINER_NAME bash -c "SPLUNK_USERNAME=$USER SPLUNK_PASSWORD=$PASSWORD /opt/splunk/bin/splunk search '|customadd first=999 second=2'"

        customSearch=$(docker exec -i -u splunk $CONTAINER_NAME bash -c "SPLUNK_USERNAME=$USER SPLUNK_PASSWORD=$PASSWORD /opt/splunk/bin/splunk search '|customadd first=999 second=2'")

        if ! echo "$customSearch" | grep -q "1001"; then
            echo -e "\033[92m Custom search command does not work correctly! \033[0m"
            # exit 1
            ((errors++))
        fi

        echo -e "\033[92m Custom search command works correctly! \033[0m"

        echo "______________________________________________________________________"

        echo -e "\033[92m Running Knowledge Object Tests... \033[0m"

        pytest -v $CI_PROJECT_DIR/tests/knowledge/test_savedsearches.py --splunk-type=external --splunk-app=$CI_PROJECT_DIR/package/ --splunk-data-generator=$CI_PROJECT_DIR/tests/knowledge/ --splunk-host=$CONTAINER_IP --splunk-port=8089 --splunk-user=$USER --splunk-password=$PASSWORD --splunk-hec-token=$HEC_TOKEN

        echo "______________________________________________________________________"

        echo -e "\033[92m Printing $APP_ROOT configuration... \033[0m"
        curl -k -u $USER:$PASSWORD -i -q https://$CONTAINER_IP:8089/services/apps/local/$APP_ROOT

        checked=1
        if $errors>0; then
        exit 1
        fi
    fi
    mainReady=1
  fi

  # if the container is no longer running...
  if [[ $health == "" ]]; then
    echo "Health:\n${health}\n"
    echo "--------------------------------"
    docker ps -a
    echo "--------------------------------"
    docker inspect $CONTAINER_NAME
    echo "--------------------------------"
    docker logs $CONTAINER_NAME
    echo "--------------------------------"
    echo "Container is no longer running!"
    exit 1
  fi

  echo "loopCounter: ${loopCounter}"
  echo "mainReady: ${mainReady}"
  sleep 5
done

if [[ $mainReady != 1 ]]; then
  echo "Timeout waiting for data to be ingested into Splunk!"
  docker logs $CONTAINER_NAME
  docker ps -a
  exit 1
fi

