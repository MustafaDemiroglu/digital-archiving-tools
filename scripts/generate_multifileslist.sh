#!/bin/bash                                                                                                                                                        
                                                                                                                                                                   
###############################################################################                                                                                    
# Script: generate_multifileslist.sh                                                                                                                               
#                                                                                                                                                                  
# Description:                                                                                                                                                     
#   This script reads a list of relative directory paths from /tmp/multifiles.list                                                                                 
#   and generates a full list of all files inside those directories.                                                                                               
#                                                                                                                                                                  
#   It is designed to automate the process of collecting file paths from                                                                                           
#   multiple folders located under a common base path (/media/cepheus),                                                                                            
#   and write the results into a single output file: /tmp/generierung.list                                                                                         
#                                                                                                                                                                  
# Usage:                                                                                                                                                           
#   - Place the list of directories into /tmp/multifiles.list (one per line)                                                                                       
#   - Run this script: ./generate_multifileslist.sh                                                                                                                
#   - Output file: /tmp/generierung.list                                                                                                                           
###############################################################################                                                                                    
                                                                                                                                                                   
# Clear the output file                                                                                                                                            
> /tmp/generierung.list                                                                                                                                            
                                                                                                                                                                   
# Input file containing the list of relative directories                                                                                                           
LIST_FILE="/tmp/multifiles.list"                                                                                                                                   
                                                                                                                                                                   
# Base directory to use if relative paths are given                                                                                                                
BASE_DIR="/media/cepheus"                                                                                                                                          
                                                                                                                                                                   
# Check if the input list file exists                                                                                                                              
if [[ ! -f "$LIST_FILE" ]]; then                                                                                                                                   
        echo "Directory list file ($LIST_FILE) not found!"                                                                                                         
        exit 1                                                                                                                                                     
fi                                                                                                                                                                 
                                                                                                                                                                   
# Read each line and process directories                                                                                                                           
while IFS= read -r LINE || [[ -n "$LINE" ]]; do                                                                                                                    
        # Skip empty lines                                                                                                                                         
        [[ -z "$LINE" ]] && continue                                                                                                                               
                                                                                                                                                                   
        # Split multiple paths per line (e.g. hstam/4_i hstam/4_k)                                                                                                 
        for REL_DIR in $LINE; do                                                                                                                                   
                # Skip if empty                                                                                                                                    
                [[ -z "$REL_DIR" ]] && continue                                                                                                                    
                                                                                                                                                                   
                # Normalize tzhe path                                                                                                                              
                REL_DIR="${REL_DIR%/}"           # Remove trailing /                                                                                               
                REL_DIR="${REL_DIR%/\*}"         # Remove trailing /*                                                                                              
                REL_DIR="${REL_DIR#./}"          # Remove trailing *                                                                                               
                REL_DIR="${REL_DIR#./}"          # Remove leading ./                                                                                               
                                                                                                                                                                   
                # Determine if path is absolute or relative                                                                                                        
                if [[ "$REL_DIR" = /* ]]; then                                                                                                                     
                        ABS_DIR="$REL_DIR"              # absolute path                                                                                            
                else                                                                                                                                               
                        ABS_DIR="$BASE_DIR/$REL_DIR"    # relative path                                                                                            
                fi                                                                                                                                                 
                                                                                                                                                                   
                # If the directory exists, find all files inside it                                                                                                
                if [[ -d "$ABS_DIR" ]]; then                                                                                                                       
                        echo "Success: $ABS_DIR"                                                                                                                   
                        find "$ABS_DIR" -type f >> /tmp/generierung.list                                                                                           
                else                                                                                                                                               
                        echo "Warning: Directory not found -> $ABS_DIR" >&2                                                                                        
                fi                                                                                                                                                 
        done                                                                                                                                                       
done < "$LIST_FILE"                                                                                                                                                
                                                                                                                                                                   
echo "List successfully created: /tmp/generierung.list"#                                                                                                           
                                                                                                                                                                   
                                                                                                                                                                   
                                                                                                                                                                   
                                                                                                                                                                   
                                                                                                                                                                   
                                                                                                                                                                   
