#!/bin/bash

JAR=target/rmlmapper-8.0.0-r381-all.jar 

java $JAVA_OPTS -jar $JAR \
  -m rules.ttl \
  -o test_out.ttl \
  -s turtle \
  -v