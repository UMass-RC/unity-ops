#!/bin/bash

source config.sh

users=$(ldapsearch -LLL -H ${LDAP_SERVER} -x -b "${LDAP_USERSEARCHBASE}" -s sub "(objectClass=posixAccount)" cn | sed -n 's/^[ \t]*cn:[ \t]*\(.*\)/\1/p')
users=$(echo $users | sed -e 's/\s\+/,/g')

existing_quotas=$(curl -u ${VAST_USER}:${VAST_PASS} --insecure -s -X GET "https://${VAST_IP}/api/quotas/" -H "accept: application/json" | jq -r '.[].name')

echo $users | tr "," "\n" | while read LINE
do
    if [ "$LINE" == "" ]; then
        continue
    fi

    if echo $existing_quotas | grep -q -w -P "home-${LINE}"; then
        echo "Quota for ${LINE} already exists, skipping..."
    else
        echo "Creating quota/directory for ${LINE}..."
        curl -u ${VAST_USER}:${VAST_PASS} --insecure -s -X POST "https://${VAST_IP}/api/quotas/" -H "accept: application/json" -H "Content-Type: application/json" -d "{ \"name\": \"home-${LINE}\", \"path\": \"${QUOTA_HOME_PATH}/${LINE}\", \"hard_limit\": ${QUOTA_HOME_AMOUNT}, \"create_dir\": \"True\" }"

        if [ $? -eq 0 ]; then
            echo "OK"
        else
            echo "FAIL"
        fi

	    install -d -m 0700 -o ${LINE} -g ${LINE} ${HOME_MOUNT_PATH}/${LINE}
    fi
done
