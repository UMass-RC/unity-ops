#!/bin/bash

set -e

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
existing_accounts=$(saccmgr show accounts -P)

# first, check if we need to add any associations
echo $pigroups | tr "," "\n" | while read group
do
    echo "Checking ${group}..."

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
        if echo $existing_associations | grep -q "${group}|${member}"; then
            echo "Association ${member} > ${group} already exists, skipping..."
        else
            # check if the account exists in sacctmgr
            if echo $existing_accounts | grep -q "${group}"; then
                # account already exists, do nothing
            else
                # account doesn't exist
                echo "Creating account ${group}"
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
                
                sacctmgr add account -i $group Organization=$org
            fi

            echo "Creating association ${member} > ${group}"

            sacctmgr add user -i $member Account=$group
        fi
    done
done

# second, check if we need to remove any associations
echo $existing_associations | while read assoc_line
do
    IFS='|' read -r -a cur_array <<< "$assoc_line"
    group=${cur_array[1]}
    member=${cur_array[2]}

    ldap_members=$(
        ldapsearch \
        -LLL \
        -x \
        -H ${LDAP_SERVER} \
        -b "cn=${group},${LDAP_PISEARCHBASE}" \
        memberuid \
        | sed -n 's/^[ \t]*memberUid:[ \t]*\(.*\)/\1/p')

    if [ $? -eq 32 ]; then
        # account no longer exists (no such object)
        echo "Account no longer exists, deleting..."

        echo "Cancelling any jobs involving this account"
        scancel -A $group
        while [ $(squeue -A $group | wc -l) -gt 1 ]; do
            # jobs are still running
            echo "Still waiting for jobs to cancel, waiting..."
            sleep 10
        done

        sacctmgr delete account -i $group
        if [ $? -eq 0 ]; then
            # account created successfully
        else
            echo "Cannot delete account, most likely because of pending jobs, waiting until next time."
        fi
    else
        # account still exists
        IFS=' ' read -r -a ldap_members_arr <<< "$ldap_members"
        if [[ ! "${ldap_members_arr[*]}" =~ "${member}" ]]; then
            # association no longer exists

            echo "Cancelling any jobs involving this association"
            scancel -A $group -u $member
            while [ $(squeue -A $group -u $member | wc -l) -gt 1 ]; do
                # jobs are still running
                echo "Still waiting for jobs to cancel, waiting..."
                sleep 10
            done

            sacctmgr delete user -i $member Account=$group
        fi
    fi

done