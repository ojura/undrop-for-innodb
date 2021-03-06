#!/bin/bash
# DB Recovery script
# v4

# init
reset
clear
echo "Init dirs"
cd ~/"undrop-for-innodb"
rm -rf ./dumps
mkdir ./dumps

# parse ibdata1
echo "Parse ibdata1"
rm -rf pages-ibdata1
./stream_parser -f $1/ibdata1 > /dev/null 2>&1

echo "Fetch DB files $1/$2"
for frmFile in $1/$2/*.frm
do
  echo "Start $frmFile"

  tableName=${frmFile##*/}
  tableName=${tableName%.frm}

  # recover data dictionary
  echo "Recover data dictionary for table $tableName"
  mysqlfrm --server=root@127.0.0.1 --port=3307 $frmFile --user=root > ./dumps/$tableName.sql

  # check if it's not a view
  testView=$(cat ./dumps/$tableName.sql | grep -oP 'CREATE ALGORITHM=.* DEFINER=.* SQL SECURITY .* VIEW `')
  if [ "" != "$testView" ]
  then
    echo "Skip view"
    continue
  fi

  # Find table index position
  echo "Find indexes table position for $tableName"
  grepdbName=${2//_/\\\\_}
  greptableName=${tableName//_/\\\\_}
  posTable=$(./c_parser -4f ./pages-ibdata1/FIL_PAGE_INDEX/0000000000000001.page -t dictionary/SYS_TABLES.sql | grep -oP "\"$grepdbName/$greptableName\"\t[0-9]*" | head -1 | grep -oP "[0-9]*$")
  echo "Indexes table position position for $tableName : $posTable"

  # Find Primary position
  echo "Find primary index position for $tableName"
  posPrimary=$(./c_parser -4f pages-ibdata1/FIL_PAGE_INDEX/0000000000000003.page -t dictionary/SYS_INDEXES.sql | grep -oP "$posTable\t[0-9]*\t\"PRIMARY" | head -1 | grep -oP "\t[0-9]*\t" | grep -oP "[0-9]*")
  echo "Primary index position for $tableName : $posPrimary"

  # Clean up some things for c_paser
  echo "Clean table DDL ./dumps/$tableName.sql"
  sed -i '/^#/d' ./dumps/$tableName.sql
  sed -i "s/$2//" ./dumps/$tableName.sql
  sed -i 's/``.//g' ./dumps/$tableName.sql
  sed -i "s/COMMENT '.*'//g" ./dumps/$tableName.sql
  sed -i "s/COMMENT='.*'//g" ./dumps/$tableName.sql
  sed -i '$s/$/;/' ./dumps/$tableName.sql
  sed -i "s/'.*''.*'/''/g" ./dumps/$tableName.sql

  # Retrieve Data
  echo "Retrieve data for $tableName"

  ibdfilename=$tableName.ibd
  ibdFile=$1/$2/$ibdfilename

  # if file per table
  if [ -e $ibdFile ]
  then
    echo "Parse $ibdFile"
    rm -rf ./pages-$ibdfilename
    ./stream_parser -f $ibdFile > /dev/null 2>&1
  else
    ibdfilename="ibdata1"
    # PAGE_INDEX not exist > exit
    if [ ! -f pages-$ibdfilename/FIL_PAGE_INDEX/`printf %016u $posPrimary`.page ]
    then
      continue
    fi
  fi

  if [ -f pages-$ibdfilename/FIL_PAGE_INDEX/`printf %016u $posPrimary`.page ]
  then
    # recover from PK
    ./c_parser -6f pages-$ibdfilename/FIL_PAGE_INDEX/`printf %016u $posPrimary`.page -b pages-$ibdfilename/FIL_PAGE_TYPE_BLOB -t ./dumps/$tableName.sql  > ./dumps/$tableName 2>> ./dumps/LoadData.sql
  else
    # recover from other FIL_PAGE_INDEX (bad pointer in ibdata1)
      for pageFile in pages-$ibdfilename/FIL_PAGE_INDEX/*.page
      do
      ipageFile=${pageFile##*/}
      ipageFile=${ipageFile%.page}
      echo $ipageFile
      ./c_parser -6f $pageFile -b pages-$ibdfilename/FIL_PAGE_TYPE_BLOB -t ./dumps/$tableName.sql  > ./dumps/$tableName$ipageFile 2>> ./dumps/LoadData.sql
    done
  fi
done

