-- Realbyte Money Manager, Android SQLite profile user_version=19 (observed).
-- Exact DDL as stored in sqlite_master, whitespace preserved. Schema only: no rows.
-- Source: supplied backups of 2026-08-10 and 2026-11-01 (identical schema).
-- sqlite_sequence is created implicitly by AUTOINCREMENT and is not listed.
PRAGMA user_version = 19;

CREATE TABLE ASSETGROUP ( DEVICE_ID 			  INTEGER PRIMARY KEY autoincrement , uid              TEXT , IS_DEL			  	  INTEGER , USETIME			    INTEGER , ACC_GROUP_NAME		VARCHAR , TYPE		 		      INTEGER , ORDERSEQ			    INTEGER , isSynced           integer , syncTime           real , syncVersion        integer  );
CREATE TABLE ASSETS (ID 	    	                  integer primary key autoincrement , CARD_DAY_FIN  	              varchar , CARD_DAY_PAY  	              varchar , NIC_NAME                     varchar , ORDERSEQ		                  integer , ZDATA                        varchar , ZDATA1                       varchar , ZDATA2                       varchar , IS_TRANS_EXPENSE             INTEGER , IS_CARD_AUTO_PAY             INTEGER , APP_PACKAGE                  varchar , APP_NAME                     varchar , SMS_TEL                      varchar , SMS_STRING                   varchar , A_UTIME     	                INTEGER , CARD_USAGE_HURDLE_TYPE 	        integer , CARD_USAGE_HURDLE_START_DATE     real , CARD_USAGE_HURDLE_AMOUNT	        real , uid         	                TEXT , currencyUid                  TEXT , cardAssetUid 	              TEXT , groupUid                     TEXT , isSynced           integer , syncTime           real , syncVersion        integer );
CREATE TABLE BUDGET (ID			          integer primary key autoincrement , uid   		        TEXT , targetUid   		  TEXT , DO_TYPE	 	      integer , PERIOD_TYPE     	integer , IS_TOTAL         integer , IS_DEL		        integer , TRANSFER_TYPE    integer , ORDER_SEQ        integer , MODIFY_DATE      integer , isSynced           integer , syncTime           real , syncVersion        integer );
CREATE TABLE BUDGET_AMOUNT (ID			          integer primary key autoincrement , uid              text , budgetUid       TEXT , IS_DEL		        integer , AMOUNT 		      real  , BUDGET_PERIOD    integer , MODIFY_DATE      integer , isSynced           integer , syncTime           real , syncVersion        integer );
CREATE TABLE CODE_DATA (id			                integer primary key autoincrement , uid   		              text , code   		            text , data   	  	          text , num       	            integer , isDel 	 	              integer , utime                  real    , ctime                  real    , isSynced               integer , syncTime               real , syncVersion            integer );
CREATE TABLE CODE_LINK (id			                integer primary key autoincrement , uid   		              text , codeUid     		        text , tableName   		        text , tableUid   	  	      text , orderSeq       	      integer , isDel 	 	              integer , utime                  real    , ctime                  real    , isSynced               integer , syncTime               real , syncVersion            integer );
CREATE TABLE CURRENCY (ID			              integer primary key autoincrement , uid       		        varchar , NAME 		            varchar , ISO                  varchar , MAIN_ISO             varchar , IS_DEL		            integer , ORDER_SEQ            integer , RATE                 real    , SYMBOL               varchar , INSERT_TYPE 	 	      varchar , SYMBOL_POSITION 	 	  varchar , IS_MAIN_CURRENCY 	  integer , IS_SHOW       	 	    integer , MODIFY_DATE          integer , DECIMAL_POINT        integer , isSynced           integer , syncTime           real , syncVersion        integer );
CREATE TABLE FAVTRANSACTION ( DEVICE_ID 			    INTEGER PRIMARY KEY autoincrement , uid	 		          TEXT , IS_DEL			 	      INTEGER , USETIME			      INTEGER , MARK			 	        INTEGER , DO_TYPE		    	  INTEGER , assetUid 		      TEXT , toAssetUid		      TEXT , ctgUid      	      TEXT , AMOUNT_SUB			    REAL	 , currencyUid        INTEGER , MEMO				        VARCHAR , PAYEE				      VARCHAR , ORDERSEQ			      INTEGER , isSynced           integer , syncTime           real , syncVersion        integer  );
CREATE TABLE INOUTCOME (AID 			            INTEGER PRIMARY KEY , uid                  TEXT , assetUid             TEXT , CARDDIVIDMONTH   VARCHAR , ctgUid      	    TEXT , toAssetUid		      TEXT , ZCONTENT 		    VARCHAR , ZDATE 			      VARCHAR , WDATE 			      VARCHAR , wtime 			      TEXT , paid 			      TEXT , DO_TYPE 		      VARCHAR , ZMONEY 		      VARCHAR , txUidTrans 	    TEXT , ZDATA 			      VARCHAR , SMS_RDATE		    VARCHAR , IN_ZMONEY 		    VARCHAR , ASSET_NIC 		  VARCHAR , CATEGORY_NAME 	  VARCHAR , cardDivideUid 	 		      TEXT , CARD_DIVIDE_MONTH_STR 	 	VARCHAR , MARK     				 	      INTEGER , txUidFee              	 	  TEXT , SMS_ORIGIN         	 	  VARCHAR , SMS_PARSE_CONTENT			  VARCHAR , IS_DEL					 	        INTEGER , UTIME						        INTEGER , currencyUid              TEXT , AMOUNT_ACCOUNT           REAL  , lat TEXT , lng TEXT , gstd TEXT , isSynced           integer , syncTime           real , syncVersion        integer  );
CREATE TABLE MEMO (id			                integer primary key autoincrement , uid   		              text , title 		              text , content                text , memoTime               real , memoDate    		        text , pinned                 integer , pinnedTime             real , orderSeq 	            integer , color       	 	        text   , isDel 	 	              integer , utime                  real    , isSynced           integer , syncTime           real , syncVersion        integer );
CREATE TABLE MESSAGEMACRO2 ( AID 			        INTEGER PRIMARY KEY autoincrement , uid              TEXT , conAssetUid 	    TEXT , MACROASSETNAME   VARCHAR , MACROTYPE 		    INTEGER , SMS_TEL 		      VARCHAR , MODIDATE 		    VARCHAR , USEYN			      VARCHAR , APP_PACKAGE	    VARCHAR , APP_NAME         VARCHAR , ORDERSEQ		      INTEGER , utime		        real , isSynced           integer , syncTime           real , syncVersion        integer  );
CREATE TABLE PHOTO ( DEVICE_ID 			  INTEGER PRIMARY KEY autoincrement , uid    	 		    TEXT , IS_DEL			 	    INTEGER , USETIME			    INTEGER , txUid		 	      TEXT , FILE_SIZE		  	INTEGER , FILE_PATH		 	  VARCHAR , FILE_NAME  	  	VARCHAR , ORG_FILE_NAME  	VARCHAR , ORG_FILE_PATH		VARCHAR  , isSynced           integer , syncTime           real , syncVersion        integer  );
CREATE TABLE REPEATTRANSACTION ( DEVICE_ID 			  INTEGER PRIMARY KEY autoincrement , uid    	 		    TEXT , IS_DEL			 	    INTEGER , USETIME			    INTEGER , MARK			 	      INTEGER , END_DATE		 	    INTEGER , NEXT_DATE			  INTEGER , DO_TYPE		 	    INTEGER , REPEAT_TYPE		  INTEGER , assetUid    		  TEXT , toAssetUid 		  TEXT , ctgUid      	    TEXT , currencyUid      TEXT , AMOUNT_SUB			  REAL	 , MEMO				      VARCHAR , PAYEE				    VARCHAR , isSynced         integer , syncTime         real , syncVersion      integer  );
CREATE TABLE SMS_RAW_READ (ID			              integer primary key autoincrement , uid                  TEXT , RDATE 		            varchar , ZDATE 		            integer , TEL	 		            varchar , ZDATA 		            varchar , MACROTYPE	          integer , assetUid             TEXT , toAssetUid           TEXT , NOTIFY_TYPE          integer , AMOUNT               varchar , TEXT_PARSING_TIME    integer , ASSETNAME	          varchar , TYPE 		            varchar , MMSID		            integer , APP_PACKAGE          varchar , APP_NAME             varchar , SENDER_NAME          varchar , IS_DEL		            integer  , utime		            real , isSynced           integer , syncTime           real , syncVersion        integer );
CREATE TABLE TAG (id			                integer primary key autoincrement , uid   		              text , name 		              text , orderSeq 	            integer , isDel 	 	              integer , utime                  real    , isSynced           integer , syncTime           real , syncVersion        integer );
CREATE TABLE TX_TAG (id			                integer primary key autoincrement , uid   		              text , txUid   		            text , tagUid   		          text , objName   		          text , orderSeq 	            integer , isDel 	 	              integer , utime                  real    , isSynced               integer , syncTime               real , syncVersion            integer );
CREATE TABLE ZCATEGORY (ID 	              integer primary key autoincrement , C_IS_DEL 	        integer , C_UTIME     	      INTEGER , uid                TEXT , NAME	 	            varchar , ORDERSEQ  	        integer , TYPE               integer , STATUS             integer , pUid               TEXT , isSynced           integer , syncTime           real , syncVersion        integer  );
CREATE TABLE ZETC (Z_PK             integer primary key autoincrement , uid              TEXT , E_UTIME     	    INTEGER , ZDATATYPE 	      integer , ZDATA     	      varchar , ZZDATA           varchar , ZZDATA1          varchar , ZZDATA2          varchar , dataTypeKey      varchar , isDel              integer , isSynced           integer , syncTime           real , syncVersion        integer  );
CREATE TABLE android_metadata (locale TEXT);
CREATE INDEX INOUTCOME_IDX2 ON INOUTCOME (DO_TYPE);
CREATE INDEX INOUTCOME_IDX3 ON INOUTCOME (ZDATE);
CREATE INDEX INOUTCOME_IDX4 ON INOUTCOME (WDATE);
CREATE INDEX INOUTCOME_IDX5 ON INOUTCOME (SMS_RDATE);
CREATE INDEX INOUTCOME_IDX6 ON INOUTCOME (UTIME);
CREATE INDEX INOUTCOME_IDX7 ON INOUTCOME (assetUid);
CREATE INDEX INOUTCOME_IDX8 ON INOUTCOME (ctgUid);
CREATE INDEX INOUTCOME_IDX9 ON INOUTCOME (currencyUid);
CREATE INDEX MESSAGEMACRO2_IDX1 ON MESSAGEMACRO2 (SMS_TEL);
CREATE INDEX SMS_RAW_READ_IDX1 ON SMS_RAW_READ (ZDATE);
CREATE INDEX SMS_RAW_READ_IDX2 ON SMS_RAW_READ (ZDATA);
CREATE INDEX SMS_RAW_READ_IDX3 ON SMS_RAW_READ (RDATE);
CREATE INDEX SMS_RAW_READ_IDX4 ON SMS_RAW_READ (assetUid);
CREATE INDEX TX_TAG_IDX1 ON TX_TAG (txUid);
CREATE UNIQUE INDEX UNIQUE_IDX_ASSETGROUP_UID ON ASSETGROUP (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_ASSETS_UID ON ASSETS (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_BUDGET_AMT_UID ON BUDGET_AMOUNT (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_BUDGET_UID ON BUDGET (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_CATEGORY_UID ON ZCATEGORY (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_CODE_DATA_UID ON CODE_DATA (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_CODE_LINK_UID ON CODE_LINK (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_CURRENCY_UID ON CURRENCY (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_ETC_UID ON ZETC (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_FAV_UID ON FAVTRANSACTION (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_INOUTCOME_UID ON INOUTCOME (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_MACRO_UID ON MESSAGEMACRO2 (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_MEMO_UID ON MEMO (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_PHOTO_UID ON PHOTO (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_REPEAT_UID ON REPEATTRANSACTION (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_SMS_UID ON SMS_RAW_READ (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_TAG_UID ON TAG (uid);
CREATE UNIQUE INDEX UNIQUE_IDX_TX_TAG_UID ON TX_TAG (uid);
