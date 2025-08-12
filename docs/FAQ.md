# Frequently Asked Questions (FAQ) - Digital Archiving Tools

**Q1: Why should I automate file archiving?**  
Automation reduces manual errors, saves time, and ensures consistency in how files are stored and managed.

**Q2: What is metadata and why is it important?**  
Metadata is data about data — like file size, creation date, author, or format. It helps you search, sort, and manage files efficiently.

**Q3: How often should I run cleanup scripts?**  
It depends on your workload, but a weekly or monthly cleanup helps keep your archive tidy and avoids storage issues.

**Q4: Can I customize the archiving scripts for my needs?**  
Yes! The scripts are designed to be simple and easy to modify for your specific folder structure or file types.

**Q5: What if I accidentally delete important files during cleanup?**  
Always keep backups of your archive. Test cleanup scripts on sample data first to avoid accidental data loss.

**Q6: How do I handle very large files or many files?**  
Consider segmenting archives by project or date, and automate archiving in batches to manage performance.

---

# FAQ - Digital Archiving Scripts

**Q1: What should I do before running these scripts?**  
Always back up your important data. Make sure you understand what the script does and test on a small dataset.

**Q2: How do I prepare the input for `generate_multifileslist.sh`?**  
Create a text file listing relative directory paths, one per line. This tells the script where to look for files.

**Q3: What happens if I run `path_cleaner_and_formatter.sh`?**  
It asks you to pick a CSV file in the current folder, then cleans up the paths inside it by removing prefixes, filenames, and duplicates.

**Q4: Can `rename_part_in_names.sh` rename folders as well as files?**  
Yes, it renames both files and directories recursively in the current folder.

**Q5: What if something goes wrong during renaming?**  
The script creates success and error logs so you can see which files were renamed and which had errors.

**Q6: Can I modify these scripts?**  
Yes, they are simple and meant to be customized for your own needs.

**Q7: How often should I run these scripts?**  
As often as your workflow requires. For example, run listing when you add new directories, cleaning before archiving, and renaming when fixing naming conventions.

---

If you have more questions or want to suggest improvements, please contribute to the project.
