#!/bin/bash

JOB_SLEEP_WAIT=$(scontrol show config | grep KillWait | sed -n -e 's/^.*= //p' | cut -d " " -f 1)
# add 30s margin to sleep wait
JOB_SLEEP_WAIT=$(($JOB_SLEEP_WAIT+30))

JOB_SLEEP_INTERVAL=5

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

existing_associations=$(sacctmgr show assoc --noheader -P)
existing_accounts=$(sacctmgr show accounts --noheader -P)

# first, check if we need to add any associations
echo "$pigroups" | while read group
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

    echo "$members" | while read member
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
                
                if [ "$org" == "" ]; then
                    echo "[CMD] sacctmgr add account -i $group"
                    if [ "$1" != "--dry" ]; then
                        sacctmgr add account -i $group
                    fi
                else
                    echo "[CMD] sacctmgr add account -i $group Organization=$org"
                    if [ "$1" != "--dry" ]; then
                        sacctmgr add account -i $group Organization=$org
                    fi
                fi
            fi

            echo "Creating association $member > $group..."

            echo "[CMD] sacctmgr add user -i $member Account=$group"
            if [ "$1" != "--dry" ]; then
                sacctmgr add user -i $member Account=$group
            fi
        fi
    done
done

# second, check if we need to remove any associations
echo "$existing_associations" | while read assoc_line
do
    IFS='|' read -r -a cur_array <<< "$assoc_line"
    group=${cur_array[1]}
    member=${cur_array[2]}

    if [ "$group" == "root" ]; then
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

    if [ $ldapCode -eq 32 ]; then
        # account no longer exists (no such object = exit code 32)

        if [ $(sacctmgr show assoc Account=$group -P --noheader | wc -l) -eq 0 ]; then
            continue
        fi

        echo "Deleting account $group..."

        echo "[CMD] scancel -A $group"
        if [ "$1" != "--dry" ]; then
            scancel -A $group
        fi

        delayCount=0
        while [ $(squeue --noheader -A $group | wc -l) -gt 0 ] && [ $delayCount -lt $JOB_SLEEP_WAIT ]
        do
            # jobs are still running
            echo "Waiting for jobs from account $group to be cancelled (sleeping $JOB_SLEEP_INTERVAL sec)..."
            delayCount=$(($delayCount + $JOB_SLEEP_INTERVAL))
            sleep $JOB_SLEEP_INTERVAL
        done

        # move user default accounts elsewhere
        group_members=$(sacctmgr show assoc -P --noheader account=$group)
        echo "$group_members" | while read member_line
        do
            IFS='|' read -r -a member_arr <<< "$member_line"
            cur_member=${member_arr[2]}
            if [ "$cur_member" == "" ]; then
                continue
            fi

            user_details=$(sacctmgr show user $cur_member --noheader -P)
            IFS='|' read -r -a user_arr <<< "$user_details"
            def_acct=${user_arr[1]}

            if [ "$def_acct" == "$group" ]; then
                # we must change the default account
                all_user_assoc=$(sacctmgr show assoc --noheader -P user=$cur_member)

                echo "$all_user_assoc" | while read all_user_line
                do
                    IFS='|' read -r -a all_user_arr <<< "$all_user_line"

                    av_acc=${all_user_arr[1]}
                    if [ "$av_acc" != "$group" ]; then
                        echo "[CMD] sacctmgr modify user -i $cur_member set defaultaccount=$av_acc"
                        if [ "$1" != "--dry" ]; then
                            sacctmgr modify user -i $cur_member set defaultaccount=$av_acc
                        fi
                        break
                    fi
                done
            fi
        done

        echo "[CMD] sacctmgr delete account -i $group"
        if [ "$1" != "--dry" ]; then
            sacctmgr delete account -i $group
        fi
    else
        # account still exists
        ldap_members_arr=(${ldap_members//$'\n'/ })
        if [[ ! "${ldap_members_arr[*]}" =~ "${member}" ]]; then
            # association no longer exists

            # check if object exists
            if [ $(sacctmgr show assoc user=$member Account=$group -P --noheader | wc -l) -eq 0 ]; then
                continue
            fi

            echo "Deleting association $member > $group..."

            echo "[CMD] scancel -A $group -u $member"
            if [ "$1" != "--dry" ]; then
                scancel -A $group -u $member
            fi

            delayCount=0
            while [ $(squeue --noheader -A $group -u $member | wc -l) -gt 0 ] && [ $delayCount -lt $JOB_SLEEP_WAIT ]
            do
                # jobs are still running
                echo "Waiting for jobs from account $group and user $member to be cancelled (sleeping $JOB_SLEEP_INTERVAL sec)..."
                delayCount=$(($delayCount + $JOB_SLEEP_INTERVAL))
                sleep $JOB_SLEEP_INTERVAL
            done

            echo "[CMD] sacctmgr delete user -i $member Account=$group"
            if [ "$1" != "--dry" ]; then
                sacctmgr delete user -i $member Account=$group
            fi
        fi
    fi

done
