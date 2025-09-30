# Unifi-Dynamic-Threat-Intel-Feed

> A script to automate the injection of external threat feeds into the UniFi platform.  
> **⚠️ Use at your own risk — this modifies UniFi’s MongoDB directly and may void warranties. Test on non-production devices first.**

---

## Overview

This tool:
- downloads a remote IP feed (FireHOL Level1 by default),
- parses & de-duplicates IP/CIDR entries,
- compares to the current UniFi `firewallgroup`,
- applies only the deltas (adds/removes) in safe batches,
- caches feed & ETag locally so it downloads only when changed.

---

1. You will need to start off with creating a sample IP group inside of the Unifi controller (you can just put a random IP in there like 1.2.3.4)

<img width="998" height="195" alt="image" src="https://github.com/user-attachments/assets/68cc55bf-954e-4c9c-b73f-74f936995ce1" />


3. Then you will need to enable ssh and ssh into your Unifi device (In my case an EFG)

4. Make a working dir inside /usr/local/sbin

#sudo mkdir -p /usr/local/sbin/unifi-ipfeed
#cd /usr/local/sbin/unifi-ipfeed

4. Install nano (I just use this because who even knows how to use Vim??)

#sudo apt install nano

5. Make a new file by copying and pasting the .sh script in this project

#nano /usr/local/sbin/unifi-ipfeed/unifi-ipfeed-update.sh

6. Install mongosh

#curl -LO https://downloads.mongodb.com/compass/mongosh-2.2.9-linux-arm64.tgz
#tar xzf mongosh-2.2.9-linux-arm64.tgz
#mv mongosh-2.2.9-linux-arm64 mongosh
#rm mongosh-2.2.9-linux-arm64.tgz

7. Log into the MongoDB to find the ID of the IP group we made earlier

mongosh/bin/mongosh "mongodb://127.0.0.1:27117/ace"

8. Run the following and find the ObjectID of the list (Should be the one that contains the example IP of 1.2.3.4):

#db.firewallgroup.find().limit(20).pretty()
#exit

9. Now go back and add the Object ID to the script file and save

#nano /usr/local/sbin/unifi-ipfeed/unifi-ipfeed-update.sh

10. Add the script as a cron job that runs every 2Hrs

#sudo crontab -e
#0 */2 * * * /usr/local/sbin/unifi-ipfeed/unifi-ipfeed-update.sh >> /usr/local/sbin/unifi-ipfeed/unifi-ipfeed.log 2>&1

11. Execute for the first time (Might take a min to run, check the UI after to see if that IP group got updated):

./unifi-ipfeed-update.sh

12. Make firewall rules in the UI now based on these dynamic threat feeds!

All done!! (Note on the script that we use FireHOL as the feed URL, and I just use their Level1 but feel free to change)
