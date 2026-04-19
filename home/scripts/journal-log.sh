#!/bin/bash

echo "Journal logs from yesterday until now:"
journalctl --since=yesterday --until=now