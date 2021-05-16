#!/bin/bash
cd home/ubuntu/eng84_cicd_jenkins/app
npm install
pm2 kill
nodejs seeds/seed.js
pm2 start app.js
