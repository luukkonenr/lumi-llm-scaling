from argparse import ArgumentParser
import sys
import os
from shutil import rmtree
from pathlib import Path
from collections import OrderedDict

def main():
    ap = ArgumentParser()
    ap.add_argument("checkpoint_dir", help="Location of checkpoint directory with checkpoint files in format 'global_stepXXX'")
    ap.add_argument("--cps_to_keep", default=5, type=int, help="How many of the latest checkpoints to keep")
    args = ap.parse_args()
    cp_path = Path(args.checkpoint_dir)

    checkpoints = [p for p in cp_path.glob("global_step[0-9]*")]
    checkpoints = {int(c.name.split("step")[-1]):c for c in checkpoints}
    checkpoints = OrderedDict(sorted(checkpoints.items(), key=lambda t: t[0]))
    sorted_paths = [path for path in checkpoints.values()]
    cps_to_del = sorted_paths[0:-args.cps_to_keep]
    cps_to_keep = sorted_paths[-args.cps_to_keep:]
    
    try:
        if cp_path.is_dir():
            tmp = cps_to_keep[args.cps_to_keep-1]
        else:
            raise NotADirectoryError()
        
    except IndexError as e:
        raise IndexError(f"Asked to keep {args.cps_to_keep} of the latest checkpoints, found {len(cps_to_keep)}.\nPlease check your arguments!\n")
    
    if len(cps_to_del)>0:
        print(f"\n# Deleting {len(cps_to_del)} checkpoints")
        for cp in cps_to_del:
            print(f"{cp.absolute()}")

        print(f"\n# Keeping the latest {args.cps_to_keep} checkpoints")
        for cp in cps_to_keep:
            print(f"Keeping {cp.absolute()}") 
        option = input("Continue? Type 'yes' to continue \n")
        print()
        if option == 'yes':
            for cp in cps_to_del:
                print(f"Deleting {cp.name}")
                rmtree(cp)
        else:
            print("Exiting and deleting nothing!")
        
        print(f"Succesfully deleted {len(cps_to_del)} checkpoints")
    else:
        print("No checkpoints to delete!")
        print("Exiting...")
        
if __name__== "__main__":
    sys.exit(main())
