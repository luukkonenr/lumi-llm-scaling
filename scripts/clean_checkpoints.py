from argparse import ArgumentParser
import sys
import os
from datetime import datetime
from shutil import rmtree, copytree
from pathlib import Path
from collections import OrderedDict



def get_cps_to_backup(backup_dir, cp_dir, backup_interval):
    backups = get_sorted_checkpoints(Path(backup_dir))
    checkpoints = get_sorted_checkpoints(cp_dir)
    if len(backups)>0:
        latest = backups[-1]
        # Find latest checkpoint backup
        for i, path in enumerate(checkpoints):
            if latest.name == path.name:
                latest_i = i
                latest = path
                dt_latest_backup = datetime.fromtimestamp(path.stat().st_mtime) # stat from cp save, not from scratch copy for correct timestamp! 
                dt_head = datetime.fromtimestamp(checkpoints[-1].stat().st_mtime)
                
                print(f"\n# Latest checkpoint on {backup_dir} is {latest.name}.\nIt's {len(checkpoints[latest_i:])-1} checkpoints and {dt_latest_backup-dt_head} behind {checkpoints[-1].name}")
                print(f"")
                break

        latest_step = latest.name.split('step')[-1]
    else:
        latest_step = 0
        latest_i = 0
    
    print(f"# Backup dir {backup_dir} has {len(backups)} checkpoints.\n")
    
    cps_to_backup = list()
    
    # Select checkpoints to copy based on backup_interval.
    for cp in checkpoints[latest_i:]:
        curr_step = cp.name.split('step')[-1]
        diff = int(curr_step) - int(latest_step)
        if diff >= backup_interval:
            # print(f"Latest saved checkpoint step is farther than the backup_interval ({backup_interval} steps)")
            cps_to_backup.append(cp)
            latest_step = curr_step
    
    return cps_to_backup
        # t1 = datetime.fromtimestamp(cp.stat().st_mtime)
        # print(cp.name, t1)
        # t2 = dt_latest_backup
        # if (t1-t2).seconds > 86000:
        #     print(cp.name)
        #     assert False





def get_sorted_checkpoints(checkpoint_dir):
    cp_path = Path(checkpoint_dir)
    checkpoints = [p for p in cp_path.glob("global_step[0-9]*")]
    checkpoints = {int(c.name.split("step")[-1]):c for c in checkpoints}
    checkpoints = OrderedDict(sorted(checkpoints.items(), key=lambda t: t[0]))
    sorted_paths = [path for path in checkpoints.values()]

    return sorted_paths


def main():
    print()
    ap = ArgumentParser()
    ap.add_argument("checkpoint_dir", help="Location of checkpoint directory with checkpoint files in format 'global_stepXXX'")
    ap.add_argument("--backup_dir", help="Location of checpoints in scratch.", default="/scratch/project_462000319/checkpoint-backups/backups-33B-fixed")
    ap.add_argument("--backup_interval", type=int, help="Interval of steps between copying checkpoint from flash to scratch. Save interval 144 makes it 2300.", default=2300)
    ap.add_argument("--cps_to_keep", default=5, type=int, help="How many of the latest checkpoints to keep")
    args = ap.parse_args()

    sorted_paths = get_sorted_checkpoints(args.checkpoint_dir)
    cps_to_del = sorted_paths[0:-args.cps_to_keep]
    cps_to_keep = sorted_paths[-args.cps_to_keep:]
    
    try:
        if Path(args.checkpoint_dir).is_dir():
            tmp = cps_to_keep[args.cps_to_keep-1]
        else:
            raise NotADirectoryError()
        
    except IndexError as e:
        raise IndexError(f"Asked to keep {args.cps_to_keep} of the latest checkpoints, found {len(cps_to_keep)}.\nPlease check your arguments!\n")
    
    try:
            if Path(args.backup_dir).is_dir():
                None
            else:
                raise NotADirectoryError()
            
    except IndexError as e:
        raise IndexError(f"Asked to keep {args.cps_to_keep} of the latest checkpoints, found {len(cps_to_keep)}.\nPlease check your arguments!\n")
    

    
    ### Check latest backup checkpoint
    ### Report how many steps ahead checkpoint_dir is
    ### Ask if want to store a copy of a checkpoint
    cps_to_backup = get_cps_to_backup(args.backup_dir, args.checkpoint_dir, args.backup_interval)
    user_backup_input = None
    user_delete_option = None


    if len(cps_to_backup)>0:
        print(f"Do you want to copy the following checkpoints to {args.backup_dir}:")
        for cp in cps_to_backup:
            print(cp.absolute())

        user_backup_input = input('\nContinue? Type "yes" to continue.\n')
        if user_backup_input == 'yes':
            print(f'Will copy checkpoints to {args.backup_dir} after the next question.')

    else:
        print("# With current settings there's not checkpoints to backup.")



    if len(cps_to_del)>0:
        print(f"\n# Deleting {len(cps_to_del)} checkpoints")
        for cp in cps_to_del:
            print(f"{cp.absolute()}")

        print(f"\n# Keeping the latest {args.cps_to_keep} checkpoints")
        for cp in cps_to_keep:
            print(f"Keeping {cp.absolute()}") 
        user_delete_option = input("Continue? Type 'yes' to continue \n")
        print()
    else:
        print("No checkpoints to delete!")
        print("Exiting...")
        
    if user_backup_input == 'yes':
        print("# Starting copying checkpoints. This can take a while. Please wait!")
        for cp in cps_to_backup:
            cur_target_path = Path.joinpath(Path(args.backup_dir), cp.name)
            print(f"Copying {cp.name} to {cur_target_path}")
            copytree(cp.absolute(), cur_target_path)
    
    print("# Starting deleting checkpoints. This will take a while. Please wait!")
    if user_delete_option == 'yes':
        for cp in cps_to_del:
            print(f"Deleting {cp.name}")
            rmtree(cp)

        print(f"Succesfully deleted {len(cps_to_del)} checkpoints")
    else:
        print("Exiting and deleting nothing!")
    
    print("All operations done!")
        
if __name__== "__main__":
    sys.exit(main())
