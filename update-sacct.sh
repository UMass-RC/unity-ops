#!/bin/bash

JOB_SLEEP_WAIT=5  # time to sleep in between checking if jobs are cancelled

source config.sh

# get list of PI groups
pigroups=$(
    ldapsearch \
    -LLL \
    -x \
    -s sub "(objectClass=posixGroup)" \
    -H ${LDAP_SERVER} \
    -b "${LDAP_PISEARCHBASE}" cn \
    | sed -n 's/^[ \t]*cn:[ \t]*\(.*\)/\1/p')
# add commas in between PI groups
pigroups=$(echo $pigroups | sed -e 's/\s\+/,/g')

existing_associations=$(sacctmgr show assoc -P)
existing_accounts=$(sacctmgr show accounts -P)

# first, check if we need to add any associations
echo $pigroups | tr "," "\n" | while read group
do
    # get members
    members=$(
        ldapsearch \
        -LLL \
        -x \
        -H ${LDAP_SERVER} \
        -b "cn=${group},${LDAP_PISEARCHBASE}" \
        memberuid \
        | sed -n 's/^[ \t]*memberUid:[ \t]*\(.*\)/\1/p')
    members=$(echo $members | sed -e 's/\s\+/,/g')

    echo $members | tr "," "\n" | while read member
    do
        if ! echo $existing_associations | grep -q "${group}|${member}"; then
            # check if the account exists in sacctmgr
            if ! echo $existing_accounts | grep -q "${group}"; then
                # account doesn't exist
                echo "Creating account $group..."

                # get owner of the group
                owner=${group#"pi_"}
                org=$(
                    ldapsearch \
                    -LLL \
                    -x \
                    -H ${LDAP_SERVER} \
                    -b "cn=${owner},${LDAP_USERSEARCHBASE}" \
                    o \
                    | sed -n 's/^[ \t]*o:[ \t]*\(.*\)/\1/p')
                
                echo "[CMD] sacctmgr add account -i $group Organization=$org"
                sacctmgr add account -i $group Organization=$org
            fi

            echo "Creating association $member > $group..."

            echo "[CMD] sacctmgr add user -i $member Account=$group"
            sacctmgr add user -i $member Account=$group
        fi
    done
done

# second, check if we need to remove any associations
echo "$existing_associations" | while read assoc_line
do
    IFS='|' read -r -a cur_array <<< "$assoc_line"
    group=${cur_array[1]}
    member=${cur_array[2]}

    if [ "$group" == "Account" ] || [ "$group" == "root" ]; then
        continue
    fi

    ldap_members=$(
        ldapsearch \
        -LLL \
        -x \
        -H ${LDAP_SERVER} \
        -b "cn=${group},${LDAP_PISEARCHBASE}" \
        memberuid)
    ldapCode=$?
    ldap_members=$(echo "$ldap_members" | sed -n 's/^[ \t]*memberUid:[ \t]*\(.*\)/\1/p')
    ldap_members=$(echo $ldap_members | sed -e 's/\s\+/,/g')

    if [ $ldapCode -eq 32 ]; then
        # account no longer exists (no such object = exit code 32)

        if [ $(sacctmgr show assoc Account=$group -P | wc -l) -le 1 ]; then
            continue
        fi

        echo "Deleting account $group..."

        echo "[CMD] scancel -A $group"
        scancel -A $group

        delayCount=0
        while [ $(squeue -A $group | wc -l) -gt 1 ] && [ $delayCount -lt 120 ]
        do
            # jobs are still running
            echo "Waiting for jobs from account $group to be cancelled (sleeping $JOB_SLEEP_WAIT sec)..."
            delayCount=$(($delayCount + $JOB_SLEEP_WAIT))
            sleep $JOB_SLEEP_WAIT
        done

        echo "[CMD] sacctmgr delete account -i $group"
        sacctmgr delete account -i $group
    else
        # account still exists
        IFS=',' read -r -a ldap_members_arr <<< "$ldap_members"
        if [[ ! "${ldap_members_arr[*]}" =~ "${member}" ]]; then
            # association no longer exists

            # check if object exists
            if [ $(sacctmgr show assoc user=$member Account=$group -P | wc -l) -le 1 ]; then
                continue
            fi

            echo "Deleting association $member > $group..."

            echo "[CMD] scancel -A $group -u $member"
            scancel -A $group -u $member

            delayCount=0
            while [ $(squeue -A $group -u $member | wc -l) -gt 1 ] && [ $delayCount -lt 120 ]
            do
                # jobs are still running
                echo "Waiting for jobs from account $group and user $member to be cancelled (sleeping $JOB_SLEEP_WAIT sec)..."
                delayCount=$(($delayCount + $JOB_SLEEP_WAIT))
                sleep $JOB_SLEEP_WAIT
            done

            echo "[CMD] sacctmgr delete user -i $member Account=$group"
            sacctmgr delete user -i $member Account=$group
        fi
    fi

done
